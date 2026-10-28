import { calculateJwkThumbprint } from "jose";
import { authorizeDevice, base64URL, bodyHash, DeviceAuthError, deviceRecords, requireUnrevokedDevice, verifyDeviceProof } from "./device-auth.mjs";
import { readDeviceJSON } from "./device-json.mjs";

// Enrollment for the explicitly configured v3 branch, never legacy traffic. The first
// owner's public key/token hash is operator-provisioned; this module never
// offers anonymous owner registration, key replacement or role=mac enrollment.
const id = value => typeof value === "string" && /^[A-Za-z0-9_-]{1,160}$/.test(value);
const digest = value => typeof value === "string" && /^[A-Za-z0-9_-]{43}$/.test(value)
  && base64URL(Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/") + "="), char => char.charCodeAt(0))) === value;
const integer = value => Number.isSafeInteger(value) && value >= 0;
const exact = (value, fields) => value && typeof value === "object" && !Array.isArray(value)
  && Object.keys(value).sort().join(",") === [...fields].sort().join(",");
const fail = (code, status = 401) => { throw new DeviceAuthError(code, status); };
const unavailable = () => fail("device_auth_state_unavailable", 503);
const scope = context => `${context.roomID}:${context.keyID}:`;
const registryKey = context => "enrollment:registry:" + scope(context);
const invitationPrefix = context => "enrollment:invitation:" + scope(context);
const invitationKey = (context, invitationID) => invitationPrefix(context) + invitationID;
// Read live admission time after IO and again at commit. A request-start
// timestamp must not freeze an invitation/proof's lifetime through a slow
// upload or queued transaction. Numeric/fake clocks exist only for offline QA.
const enrollmentClock = time => () => {
  const value = typeof time === "function" ? time() : (time === undefined ? Date.now() : time);
  if (!integer(value)) unavailable();
  return value;
};

function rootsFor(raw, context) {
  const all = deviceRecords(raw);
  if (!all) fail("device_auth_not_configured", 503);
  const roots = all.filter(record => record.roomID === context.roomID && record.keyID === context.keyID);
  if (!roots.some(record => record.role === "mac")) fail("device_auth_not_configured", 503);
  return roots;
}
function mergeRegistry(document, roots, context) {
  if (document === undefined) return roots;
  if (!exact(document, ["version", "roomID", "keyID", "grants"]) || document.version !== 1
      || document.roomID !== context.roomID || document.keyID !== context.keyID || !Array.isArray(document.grants)
      || document.grants.some(grant => !grant || grant.roomID !== context.roomID || grant.keyID !== context.keyID
        || (grant.role !== "phone" && grant.role !== "watch"))) unavailable();
  const merged = deviceRecords(JSON.stringify([...roots, ...document.grants]));
  if (!merged) unavailable();
  return merged;
}
export async function enrolledDeviceRecords(storage, rawRoots, context) {
  const roots = rootsFor(rawRoots, context);
  try { return mergeRegistry(await storage.get(registryKey(context)), roots, context); }
  catch (error) { if (error instanceof DeviceAuthError) throw error; unavailable(); }
}
function validInvitation(value, context) {
  const fields = ["version", "roomID", "keyID", "invitationID", "ownerID", "ownerThumbprint", "role", "secretHash", "nonce", "issuedAt", "expiresAt", "grantExpiresAt", "createDigest", "receipt"];
  if (!exact(value, fields) || value.version !== 1 || value.roomID !== context.roomID || value.keyID !== context.keyID
      || !id(value.invitationID) || !id(value.ownerID) || !["phone", "watch"].includes(value.role)
      || !digest(value.ownerThumbprint) || !digest(value.secretHash) || !digest(value.nonce) || !digest(value.createDigest)
      || !integer(value.issuedAt) || !integer(value.expiresAt) || value.expiresAt <= value.issuedAt
      || value.expiresAt > value.issuedAt + 120_000
      || !integer(value.grantExpiresAt) || value.grantExpiresAt <= value.expiresAt) return false;
  return value.receipt === null || (exact(value.receipt, ["bodyDigest", "deviceID"])
    && digest(value.receipt.bodyDigest) && id(value.receipt.deviceID));
}
const publicInvitation = value => ({ invitationID: value.invitationID, role: value.role, nonce: value.nonce,
  expiresAt: value.expiresAt, grantExpiresAt: value.grantExpiresAt, ownerID: value.ownerID,
  ownerThumbprint: value.ownerThumbprint, consumed: value.receipt !== null });
const publicGrant = value => ({ roomID: value.roomID, keyID: value.keyID, deviceID: value.deviceID,
  role: value.role, jwk: value.jwk, expiresAt: value.expiresAt });
const sameGrant = (left, right) => left && left.roomID === right.roomID && left.keyID === right.keyID
  && left.deviceID === right.deviceID && left.role === right.role && left.tokenHash === right.tokenHash
  && left.expiresAt === right.expiresAt && left.revokedAt === right.revokedAt
  && left.jwk?.kty === right.jwk.kty && left.jwk?.crv === right.jwk.crv && left.jwk?.x === right.jwk.x;
const sameInvitation = (left, right) => ["roomID", "keyID", "invitationID", "ownerID", "ownerThumbprint", "role",
  "secretHash", "nonce", "issuedAt", "expiresAt", "grantExpiresAt", "createDigest"].every(key => left[key] === right[key]);

async function readBody(request) {
  try {
    return await readDeviceJSON(request, 8192, "enrollment");
  } catch (error) {
    // Preserve the installed candidate's public error spelling.
    if (error instanceof DeviceAuthError && error.code === "enrollment_invalid_body") fail("invalid_enrollment_body", 400);
    throw error;
  }
}

export async function createEnrollmentInvitation(request, context, rawRoots, storage, time) {
  const clock = enrollmentClock(time);
  if (request.method !== "POST" || context.resource !== "devices/invitations") fail("device_role_forbidden", 403);
  const { value, bodyDigest } = await readBody(request);
  const now = clock();
  if (!exact(value, ["invitationID", "role", "secretHash", "expiresAt", "grantExpiresAt"]) || !id(value.invitationID)
      || !["phone", "watch"].includes(value.role) || !digest(value.secretHash)
      || !integer(value.expiresAt) || value.expiresAt > now + 120_000
      || !integer(value.grantExpiresAt) || value.grantExpiresAt <= value.expiresAt) fail("invalid_enrollment_body", 400);
  // The absolute invitation deadline is inside the signed body. Even after
  // expired invitation GC, a delayed exact request cannot mint a new deadline.
  if (value.expiresAt <= now) fail("enrollment_invitation_expired", 410);
  const records = await enrolledDeviceRecords(storage, rawRoots, context);
  const authorization = await authorizeDevice(request, { ...context, bodyDigest }, JSON.stringify(records), storage, clock);
  if (!authorization.authorized) return authorization;
  const owner = authorization.principal;
  const ownerRecord = records.find(record => record.deviceID === owner.deviceID);
  if (value.grantExpiresAt > ownerRecord.expiresAt || value.secretHash === ownerRecord.tokenHash) fail("invalid_enrollment_body", 400);
  const currentOfferTime = () => {
    const valueNow = clock();
    if (ownerRecord.expiresAt <= valueNow) fail("invalid_dpop_proof");
    if (value.expiresAt <= valueNow) fail("enrollment_invitation_expired", 410);
    return valueNow;
  };
  try {
    const result = await storage.transaction(async transaction => {
      await requireUnrevokedDevice(transaction, owner);
      const key = invitationKey(context, value.invitationID), existing = await transaction.get(key);
      if (existing !== undefined) {
        if (!validInvitation(existing, context)) unavailable();
        if (existing.ownerID !== owner.deviceID || existing.ownerThumbprint !== owner.thumbprint || existing.createDigest !== bodyDigest) fail("enrollment_invitation_conflict", 409);
        currentOfferTime();
        // Retrying the exact owner request reads its original result. No new
        // secret/nonce/deadline is generated or extended after an ACK loss.
        return { authorized: true, invitation: publicInvitation(existing) };
      }
      const invitations = await transaction.list({ prefix: invitationPrefix(context), limit: 65 });
      const committedAt = currentOfferTime();
      if (invitations.size > 64) unavailable();
      const expired = [];
      for (const [storedKey, entry] of invitations) {
        if (!validInvitation(entry, context) || storedKey !== invitationKey(context, entry.invitationID)) unavailable();
        if (entry.expiresAt <= committedAt) expired.push(storedKey);
      }
      if (invitations.size - expired.length >= 64) fail("enrollment_capacity", 429);
      if (expired.length) await transaction.delete(expired);
      const invitation = { version: 1, roomID: context.roomID, keyID: context.keyID, invitationID: value.invitationID,
        ownerID: owner.deviceID, ownerThumbprint: owner.thumbprint, role: value.role, secretHash: value.secretHash,
        nonce: base64URL(crypto.getRandomValues(new Uint8Array(32))), issuedAt: committedAt, expiresAt: value.expiresAt,
        grantExpiresAt: value.grantExpiresAt, createDigest: bodyDigest, receipt: null };
      await transaction.put(key, invitation);
      // Expiry can pass while the durable write is pending. Throw within the
      // transaction so no unusable invitation is committed as a success.
      currentOfferTime();
      return { authorized: true, invitation: publicInvitation(invitation) };
    });
    // A slow commit/transaction-return can finish after the last callback
    // check. The row may already be committed: preserve it, but do not report
    // an expired authorization as usable or attempt to replace it.
    currentOfferTime();
    return result;
  } catch (error) { if (error instanceof DeviceAuthError) throw error; unavailable(); }
}

// Lost creation ACK recovery is an authenticated known-ID lookup, never a
// request to recreate/renew an invitation. Only public result fields and the
// hash of the exact original creation body leave storage. Authorization still
// records nonce/replay state; the invitation/registry business rows are read-only.
export async function readEnrollmentInvitation(request, context, rawRoots, storage, time) {
  const clock = enrollmentClock(time);
  const match = /^devices\/invitations\/([A-Za-z0-9_-]{1,160})$/.exec(context.resource);
  if (request.method !== "GET" || !match) fail("device_role_forbidden", 403);
  if (request.body !== null) fail("unexpected_device_body", 400);
  const records = await enrolledDeviceRecords(storage, rawRoots, context);
  const authorization = await authorizeDevice(request, context, JSON.stringify(records), storage, clock);
  if (!authorization.authorized) return authorization;
  const owner = authorization.principal;
  try {
    const result = await storage.transaction(async transaction => {
      await requireUnrevokedDevice(transaction, owner);
      const invitation = await transaction.get(invitationKey(context, match[1]));
      // Recheck after the last storage await, even for an absent ID. A slow
      // lookup must not disclose a result after the owner's grant expires.
      if (owner.expiresAt <= clock()) fail("invalid_dpop_proof");
      if (invitation === undefined) return { authorized: true };
      if (!validInvitation(invitation, context) || invitation.invitationID !== match[1]) unavailable();
      // Other legitimate owners cannot enumerate this owner's invitation.
      if (invitation.ownerID !== owner.deviceID || invitation.ownerThumbprint !== owner.thumbprint) return { authorized: true };
      if (invitation.expiresAt <= clock()) fail("enrollment_invitation_expired", 410);
      return { authorized: true, invitation: publicInvitation(invitation), createDigest: invitation.createDigest };
    });
    const completedAt = clock();
    if (owner.expiresAt <= completedAt) fail("invalid_dpop_proof");
    if (result.invitation && result.invitation.expiresAt <= completedAt) fail("enrollment_invitation_expired", 410);
    return result;
  } catch (error) { if (error instanceof DeviceAuthError) throw error; unavailable(); }
}

export async function redeemEnrollmentInvitation(request, context, rawRoots, storage, time) {
  const clock = enrollmentClock(time);
  if (request.method !== "POST" || context.resource !== "devices/enroll") fail("device_role_forbidden", 403);
  const { value, bodyDigest } = await readBody(request);
  if (!exact(value, ["invitationID", "deviceID", "jwk", "tokenHash"]) || !id(value.invitationID) || !id(value.deviceID) || !digest(value.tokenHash)) fail("invalid_enrollment_body", 400);
  const roots = rootsFor(rawRoots, context);
  let invitation;
  try { invitation = await storage.get(invitationKey(context, value.invitationID)); }
  catch { unavailable(); }
  const now = clock();
  if (!validInvitation(invitation, context)) { if (invitation === undefined) fail("invalid_enrollment_invitation"); unavailable(); }
  const ownerRecord = roots.find(record => record.deviceID === invitation.ownerID && record.role === "mac");
  if (!ownerRecord || ownerRecord.expiresAt <= now || (ownerRecord.revokedAt !== undefined && ownerRecord.revokedAt <= now)
      || await calculateJwkThumbprint(ownerRecord.jwk) !== invitation.ownerThumbprint) fail("invalid_enrollment_invitation");
  if (value.tokenHash === invitation.secretHash || value.tokenHash === ownerRecord.tokenHash) fail("invalid_enrollment_body", 400);
  const grant = { roomID: context.roomID, keyID: context.keyID, deviceID: value.deviceID,
    role: invitation.role, jwk: value.jwk, tokenHash: value.tokenHash, expiresAt: invitation.grantExpiresAt };
  if (!deviceRecords(JSON.stringify([grant]))) fail("invalid_enrollment_body", 400);
  const temporary = { ...grant, tokenHash: invitation.secretHash, expiresAt: invitation.expiresAt };
  // The out-of-band high-entropy invitation authorizes enrollment, not a
  // self-signed public key. This verifies possession of BOTH the invitation
  // secret and the prospective device key, including the exact received body.
  const verified = await verifyDeviceProof(request, { ...context, bodyDigest }, JSON.stringify([temporary]), clock());
  if (verified.nonce !== invitation.nonce) fail("invalid_enrollment_invitation");
  try {
    return await storage.transaction(async transaction => {
      await requireUnrevokedDevice(transaction, ownerRecord);
      await requireUnrevokedDevice(transaction, grant);
      const current = await transaction.get(invitationKey(context, value.invitationID));
      if (!validInvitation(current, context)) unavailable();
      const document = await transaction.get(registryKey(context)), records = mergeRegistry(document, roots, context);
      const committedAt = clock();
      if (ownerRecord.expiresAt <= committedAt || current.expiresAt <= committedAt
          || current.grantExpiresAt <= committedAt || !sameInvitation(current, invitation)) fail("invalid_enrollment_invitation");
      if (current.receipt !== null) {
        const original = records.find(record => record.deviceID === current.receipt.deviceID);
        if (current.receipt.bodyDigest !== bodyDigest || current.receipt.deviceID !== grant.deviceID) fail("enrollment_invitation_used", 409);
        if (!sameGrant(original, grant)) unavailable();
        // Exact repeated enrollment only returns its public original grant;
        // it cannot create/replace/renew a device or execute a user action.
        return { enrolled: true, alreadyEnrolled: true, grant: publicGrant(original) };
      }
      if (records.length >= 64) fail("enrollment_capacity", 429);
      const merged = deviceRecords(JSON.stringify([...records, grant]));
      if (!merged) fail("enrolled_identity_conflict", 409);
      const grants = [...(document?.grants ?? []), grant];
      await transaction.put(registryKey(context), { version: 1, roomID: context.roomID, keyID: context.keyID, grants });
      await transaction.put(invitationKey(context, value.invitationID), { ...current, receipt: { bodyDigest, deviceID: grant.deviceID } });
      return { enrolled: true, alreadyEnrolled: false, grant: publicGrant(grant) };
    });
  } catch (error) { if (error instanceof DeviceAuthError) throw error; unavailable(); }
}

// Recovery after a lost enrollment ACK uses the previously persisted new
// device identity, not the expired invitation. It returns only that device's
// public grant, and rechecks revocation in the read-result transaction.
export async function readOwnEnrollment(request, context, rawRoots, storage, time) {
  const clock = enrollmentClock(time);
  if (request.method !== "GET" || context.resource !== "devices/me") fail("device_role_forbidden", 403);
  const records = await enrolledDeviceRecords(storage, rawRoots, context);
  const authorization = await authorizeDevice(request, context, JSON.stringify(records), storage, clock);
  if (!authorization.authorized) return authorization;
  try {
    return await storage.transaction(async transaction => {
      await requireUnrevokedDevice(transaction, authorization.principal);
      const current = mergeRegistry(await transaction.get(registryKey(context)), rootsFor(rawRoots, context), context);
      const record = current.find(value => value.deviceID === authorization.principal.deviceID);
      if (!record || !sameGrant(record, records.find(value => value.deviceID === record.deviceID))) unavailable();
      if (record.expiresAt <= clock()) fail("invalid_dpop_proof");
      return { authorized: true, grant: publicGrant(record) };
    });
  } catch (error) { if (error instanceof DeviceAuthError) throw error; unavailable(); }
}
