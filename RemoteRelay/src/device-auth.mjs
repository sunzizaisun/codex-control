import { calculateJwkThumbprint, decodeProtectedHeader, importJWK, jwtVerify } from "jose";

// Device identity for the explicit v3 route; existing v1/v2 traffic remains
// separate until coordinated migration. Native enrollment, signed envelopes
// and full cutover must be ready before enabling it. DPoP is NOT enrollment and does
// not sign a request body (RFC 9449 sections 1 and 11.7).
const roles = new Set(["mac", "phone", "watch"]);
const id = value => typeof value === "string" && /^[A-Za-z0-9_-]{1,160}$/.test(value);
const keyID = value => typeof value === "string" && /^[a-f0-9]{32}$/.test(value);
const integer = value => Number.isSafeInteger(value) && value >= 0;
const exactKeys = (value, keys) => value && typeof value === "object" && !Array.isArray(value)
  && Object.keys(value).sort().join(",") === [...keys].sort().join(",");

export class DeviceAuthError extends Error {
  constructor(code, status = 401) { super(code); this.code = code; this.status = status; }
}
function invalid() { throw new DeviceAuthError("invalid_dpop_proof"); }
function stateUnavailable() { throw new DeviceAuthError("device_auth_state_unavailable", 503); }
export const base64URL = data => {
  let binary = ""; for (const value of new Uint8Array(data)) binary += String.fromCharCode(value);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/g, "");
};
function decodeBase64URL(value, bytes) {
  if (typeof value !== "string" || !/^[A-Za-z0-9_-]+$/.test(value) || value.length > 16_384) return null;
  try {
    const binary = atob(value.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - value.length % 4) % 4));
    const result = Uint8Array.from(binary, char => char.charCodeAt(0));
    return result.length === bytes && base64URL(result) === value ? result : null;
  } catch { return null; }
}
const publicJWK = value => exactKeys(value, ["kty", "crv", "x"])
  && value.kty === "OKP" && value.crv === "Ed25519" && !!decodeBase64URL(value.x, 32);
export const tokenHash = async value => base64URL(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
// Private application profile, not a guarantee provided by standard DPoP.
// Routes must compute bodyDigest from their bounded, actually received bytes.
export const BODY_HASH_CLAIM = "urn:codex-control:relay:v3:body-sha256";
export const bodyHash = async bytes => base64URL(await crypto.subtle.digest("SHA-256", bytes));
function equalDigest(left, right) {
  const a = decodeBase64URL(left, 32), b = decodeBase64URL(right, 32);
  if (!a || !b) return false;
  // Both are fixed-length digest bytes, never variable-size secrets.
  let difference = 0; for (let index = 0; index < 32; index++) difference |= a[index] ^ b[index];
  return difference === 0;
}
export function targetURI(raw) {
  let url; try { url = new URL(raw); } catch { invalid(); }
  if (url.protocol !== "https:" || url.username || url.password || !url.hostname) invalid();
  url.search = ""; url.hash = "";
  return url.href;
}

/// Only public keys and token hashes belong in the server registry. Reject
/// unknown fields, private JWKs and duplicates; no encryption/bootstrap key.
export function deviceRecords(raw) {
  let records; try { records = JSON.parse(raw); } catch { return null; }
  if (!Array.isArray(records) || records.length < 1 || records.length > 64) return null;
  const identities = new Set(), tokens = new Set(), keys = new Set();
  for (const record of records) {
    const required = ["roomID", "keyID", "deviceID", "role", "tokenHash", "jwk", "expiresAt"];
    const fields = record && Object.hasOwn(record, "revokedAt") ? [...required, "revokedAt"] : required;
    if (!exactKeys(record, fields) || !id(record.roomID) || !keyID(record.keyID) || !id(record.deviceID)
        || !roles.has(record.role) || !decodeBase64URL(record.tokenHash, 32) || !publicJWK(record.jwk)
        || !integer(record.expiresAt) || record.expiresAt === 0
        || (Object.hasOwn(record, "revokedAt") && !integer(record.revokedAt))) return null;
    const epoch = `${record.roomID}:${record.keyID}:`;
    for (const [set, value] of [[identities, epoch + record.deviceID], [tokens, epoch + record.tokenHash], [keys, epoch + record.jwk.x]]) {
      if (set.has(value)) return null; set.add(value);
    }
  }
  return records;
}

export function roleAllows(role, method, resource) {
  if (!roles.has(role) || typeof resource !== "string" || resource.includes("?") || resource.includes("#")) return false;
  if (resource === "snapshot") return method === "GET" || (role === "mac" && method === "PUT");
  if (resource === "devices/invitations") return role === "mac" && method === "POST";
  if (/^devices\/invitations\/[A-Za-z0-9_-]{1,160}$/.test(resource)) return role === "mac" && method === "GET";
  if (resource === "devices/me") return method === "GET";
  if (resource === "devices/peers") return method === "GET";
  if (resource === "devices/key-requests") return role === "mac" && method === "GET";
  if (resource === "devices/me/key-request") return role !== "mac" && ["GET", "POST"].includes(method);
  if (resource === "devices/me/room-key") return role !== "mac" && method === "GET";
  if (/^devices\/key-responses\/[A-Za-z0-9_-]{1,160}$/.test(resource)) return role === "mac" && ["GET", "POST"].includes(method);
  const parts = resource.split("/");
  if (parts[0] === "devices" && parts.length === 3 && parts[2] === "revoke" && id(parts[1])) {
    return role === "mac" && method === "POST";
  }
  if (parts[0] === "stream" && parts.length === 2) return method === "GET" && parts[1] === role;
  if (parts[0] !== "mailbox" || !roles.has(parts[1])) return false;
  if (parts.length === 2) {
    if (method === "GET") return parts[1] === role;
    if (method === "POST") return role === "mac" ? parts[1] !== "mac" : parts[1] === "mac";
  }
  return parts.length === 3 && method === "DELETE" && parts[1] === role && id(parts[2]);
}

/// Validates signature and key/token binding, but not nonce/replay state.
/// externalURL is the actual original target URI, supplied by trusted routing,
/// never a client-provided forwarding header. Call authorizeDevice afterwards.
export async function verifyDeviceProof(request, context, rawRecords, now = Date.now()) {
  const records = deviceRecords(rawRecords);
  if (!records) throw new DeviceAuthError("device_auth_not_configured", 503);
  if (!integer(now) || !id(context.roomID) || !keyID(context.keyID)) invalid();
  const actualTarget = targetURI(context.externalURL ?? request.url);
  if (typeof context.resource !== "string"
      || new URL(actualTarget).pathname !== `/v3/rooms/${context.roomID}/${context.resource}`) invalid();
  const token = /^DPoP ([A-Za-z0-9_-]{43})$/i.exec(request.headers.get("Authorization") || "")?.[1];
  const proof = request.headers.get("DPoP") || "";
  if (!token || !decodeBase64URL(token, 32) || proof.length > 4096
      || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(proof)) invalid();
  const digest = await tokenHash(token);
  const record = records.find(value => value.roomID === context.roomID && value.keyID === context.keyID
    && equalDigest(value.tokenHash, digest));
  if (!record || record.expiresAt <= now || (record.revokedAt !== undefined && record.revokedAt <= now)) invalid();
  let claims, header, thumbprint;
  try {
    header = decodeProtectedHeader(proof);
    if (!exactKeys(header, ["alg", "typ", "jwk"]) || header.alg !== "Ed25519" || header.typ !== "dpop+jwt"
        || !publicJWK(header.jwk) || header.jwk.x !== record.jwk.x) invalid();
    const key = await importJWK(record.jwk, "Ed25519");
    ({ payload: claims } = await jwtVerify(proof, key, {
      algorithms: ["Ed25519"], typ: "dpop+jwt", currentDate: new Date(now),
      maxTokenAge: 60, clockTolerance: 5, requiredClaims: ["iat", "jti", "htm", "htu", "ath"],
    }));
    thumbprint = await calculateJwkThumbprint(record.jwk);
  } catch { invalid(); }
  if (!integer(claims.iat) || typeof claims.jti !== "string" || !/^[A-Za-z0-9_-]{16,160}$/.test(claims.jti)
      || claims.htm !== request.method || typeof claims.htu !== "string"
      || claims.htu !== targetURI(claims.htu) || claims.htu !== actualTarget
      || !equalDigest(claims.ath, digest)
      || (claims[BODY_HASH_CLAIM] !== undefined && !decodeBase64URL(claims[BODY_HASH_CLAIM], 32))
      || (context.requireBodyDigest === true && claims[BODY_HASH_CLAIM] === undefined)
      || (context.bodyDigest !== undefined && !equalDigest(claims[BODY_HASH_CLAIM], context.bodyDigest))
      || (claims.nonce !== undefined && (typeof claims.nonce !== "string" || !/^[A-Za-z0-9_-]{1,160}$/.test(claims.nonce)))) invalid();
  return { principal: { deviceID: record.deviceID, role: record.role, roomID: record.roomID,
    keyID: record.keyID, thumbprint, expiresAt: record.expiresAt }, jti: claims.jti, nonce: claims.nonce, issuedAt: claims.iat };
}

const authorizationClock = time => () => {
  const value = typeof time === "function" ? time() : time === undefined ? Date.now() : time;
  if (!integer(value)) stateUnavailable();
  return value;
};
function requireCurrentProof(verified, now) {
  const seconds = Math.floor(now / 1000);
  if (verified.principal.expiresAt <= now || seconds - verified.issuedAt > 65 || verified.issuedAt > seconds + 5) invalid();
}

const replayPrefix = "device-auth:replay:";
const noncePrefix = "device-auth:nonce:";
const revokedPrefix = "device-auth:revoked:";
const stateScope = principal => `${principal.roomID}:${principal.keyID}:`;
function validNonce(value) {
  return exactKeys(value, ["version", "nonce", "expiresAt"]) && value.version === 1
    && !!decodeBase64URL(value.nonce, 32) && integer(value.expiresAt);
}
function validReplay(value) {
  return exactKeys(value, ["version", "expiresAt"]) && value.version === 1 && integer(value.expiresAt);
}
function validRevocation(value) {
  return exactKeys(value, ["version", "revokedAt", "by"]) && value.version === 1
    && integer(value.revokedAt) && id(value.by);
}

// State check only; this does NOT authenticate a plain principal object.
// Callers must first prove the corresponding registered key/token or invite.
export async function requireUnrevokedDevice(transaction, principal) {
  if (await deviceRevocation(transaction, principal)) invalid();
}

// Public revocation metadata only; no token/key material is returned. This
// helper does not authenticate a plain principal, just like the state gate.
export async function deviceRevocation(transaction, principal) {
  const revoked = await transaction.get(revokedPrefix + stateScope(principal) + principal.deviceID);
  if (revoked !== undefined && !validRevocation(revoked)) stateUnavailable();
  return revoked;
}

/// Uses the DO transaction API, not in-memory claims. An evicted instance must
/// not accept an already-consumed proof. No network or crypto awaits in the
/// transaction; signature verification was completed before reserving state.
export async function authorizeDevice(request, context, rawRecords, storage, time) {
  const clock = authorizationClock(time);
  const verified = await verifyDeviceProof(request, context, rawRecords, clock());
  if (!roleAllows(verified.principal.role, request.method, context.resource)) throw new DeviceAuthError("device_role_forbidden", 403);
  const principal = verified.principal;
  const scope = stateScope(principal);
  const replayKey = replayPrefix + scope + principal.deviceID + ":" + await tokenHash(verified.jti);
  const nonceKey = noncePrefix + scope + principal.deviceID;
  try {
    return await storage.transaction(async transaction => {
      await requireUnrevokedDevice(transaction, principal);
      const current = await transaction.get(nonceKey);
      const now = clock(); requireCurrentProof(verified, now);
      if (current !== undefined && !validNonce(current)) stateUnavailable();
      if (!current || current.expiresAt <= now || verified.nonce !== current.nonce) {
        let nonce = current;
        if (!nonce || nonce.expiresAt <= now) {
          nonce = { version: 1, nonce: base64URL(crypto.getRandomValues(new Uint8Array(32))), expiresAt: now + 120_000 };
          await transaction.put(nonceKey, nonce);
        }
        return { authorized: false, nonce: nonce.nonce };
      }
      const replays = await transaction.list({ prefix: replayPrefix, limit: 1025 });
      const admittedAt = clock(); requireCurrentProof(verified, admittedAt);
      if (current.expiresAt <= admittedAt) {
        const nonce = { version: 1, nonce: base64URL(crypto.getRandomValues(new Uint8Array(32))), expiresAt: admittedAt + 120_000 };
        await transaction.put(nonceKey, nonce);
        return { authorized: false, nonce: nonce.nonce };
      }
      if (replays.size > 1024) stateUnavailable();
      const expired = [];
      for (const [key, value] of replays) {
        if (!validReplay(value)) stateUnavailable();
        if (value.expiresAt <= admittedAt) expired.push(key);
      }
      if (replays.has(replayKey) && replays.get(replayKey).expiresAt > admittedAt) throw new DeviceAuthError("dpop_proof_replayed");
      if (replays.size - expired.length >= 1024) throw new DeviceAuthError("device_auth_busy", 429);
      if (expired.length) await transaction.delete(expired);
      await transaction.put(replayKey, { version: 1, expiresAt: admittedAt + 120_000 });
      return { authorized: true, principal };
    });
  } catch (error) {
    if (error instanceof DeviceAuthError) throw error;
    stateUnavailable();
  }
}

/// Revocation is monotonic and does not cancel already-admitted commands.
/// This API verifies the actual owner request; a caller cannot provide a plain
/// JSON object claiming role=mac instead of proving the owner's enrolled key.
export async function revokeDevice(request, context, rawRecords, storage, deviceID, time) {
  const clock = authorizationClock(time);
  if (!id(deviceID) || context.resource !== `devices/${deviceID}/revoke` || request.method !== "POST") {
    throw new DeviceAuthError("device_role_forbidden", 403);
  }
  const authorization = await authorizeDevice(request, context, rawRecords, storage, clock);
  if (!authorization.authorized) return authorization;
  const principal = authorization.principal;
  if (!deviceRecords(rawRecords).some(record => record.roomID === principal.roomID && record.keyID === principal.keyID
      && record.deviceID === deviceID)) throw new DeviceAuthError("device_not_found", 404);
  if (principal.deviceID === deviceID) throw new DeviceAuthError("cannot_revoke_current_owner", 409);
  try {
    await storage.transaction(async transaction => {
      await requireUnrevokedDevice(transaction, principal);
      if (principal.expiresAt <= clock()) invalid();
      const revokedKey = revokedPrefix + stateScope(principal) + deviceID;
      const existing = await transaction.get(revokedKey);
      if (existing !== undefined && !validRevocation(existing)) stateUnavailable();
      if (principal.expiresAt <= clock()) invalid();
      if (!existing) await transaction.put(revokedKey, { version: 1, revokedAt: clock(), by: principal.deviceID });
    });
  } catch (error) { if (error instanceof DeviceAuthError) throw error; stateUnavailable(); }
  return { ...authorization, revoked: true };
}
