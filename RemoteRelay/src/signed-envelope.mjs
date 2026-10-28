import { base64url, calculateJwkThumbprint, compactVerify, CompactSign, decodeProtectedHeader, importJWK } from "jose";

// Reference / isolated interoperability codec. The live relay never decrypts
// this content and index.js does NOT import this module. No enrollment, user
// presence, command execution or receipt is implied by a verified signature.
export const SIGNED_ENVELOPE_TYPE = "codex-relay-envelope+jws";
export const MAX_ENVELOPE_BYTES = 750_000, MAX_COMPACT_BYTES = 1_420_000;
const encoder = new TextEncoder(), decoder = new TextDecoder("utf-8", { fatal: true });
const id = value => typeof value === "string" && /^[A-Za-z0-9_-]{1,160}$/.test(value);
const epoch = value => typeof value === "string" && /^[a-f0-9]{32}$/.test(value);
const integer = value => Number.isSafeInteger(value) && value >= 0;
const roles = new Set(["mac", "phone", "watch"]), destinations = new Set([...roles, "snapshot"]);
const fields = ["version", "roomID", "keyID", "destination", "senderDeviceID", "senderRole", "messageID", "sentAt", "expiresAt", "envelope"];
const kinds = new Set(["hello", "requestSnapshot", "snapshot", "approvalDecision", "taskCommand", "usageReset", "acknowledgement", "error"]);
const exactKeys = (value, keys) => value && typeof value === "object" && !Array.isArray(value)
  && Object.keys(value).sort().join(",") === [...keys].sort().join(",");
export class SignedEnvelopeError extends Error {
  constructor(code = "invalid_signed_envelope") { super(code); this.code = code; }
}
const invalid = () => { throw new SignedEnvelopeError(); };
const equalBytes = (a, b) => a.length === b.length && a.every((value, index) => value === b[index]);
export const canonicalFlatJSON = value => JSON.stringify(Object.fromEntries(Object.keys(value).sort().map(key => [key, value[key]])));
function decodeCanonical(value, maximumBytes) {
  if (typeof value !== "string" || !value.length || value.length > maximumBytes || !/^[A-Za-z0-9_-]+$/.test(value)) invalid();
  let bytes; try { bytes = base64url.decode(value); } catch { invalid(); }
  if (base64url.encode(bytes) !== value) invalid();
  return bytes;
}
function validateIdentity(value, now) {
  const required = ["roomID", "keyID", "deviceID", "role", "jwk", "expiresAt"];
  if (!exactKeys(value, value && Object.hasOwn(value, "revokedAt") ? [...required, "revokedAt"] : required)
      || !id(value.roomID) || !epoch(value.keyID) || !id(value.deviceID) || !roles.has(value.role)
      || !integer(value.expiresAt) || !exactKeys(value.jwk, ["kty", "crv", "x"])
      || value.jwk.kty !== "OKP" || value.jwk.crv !== "Ed25519"
      || decodeCanonical(value.jwk.x, 43).length !== 32 || !integer(now)
      || (value.revokedAt !== undefined && !integer(value.revokedAt))) invalid();
  if (value.expiresAt <= now || (value.revokedAt !== undefined && value.revokedAt <= now)) throw new SignedEnvelopeError("signed_identity_expired");
}
const allows = (role, destination) => destinations.has(destination) && (role === "mac" ? destination !== "mac" : destination === "mac");
function parseOriginal(bytes, now) {
  if (bytes.byteLength > MAX_ENVELOPE_BYTES) throw new SignedEnvelopeError("signed_envelope_too_large");
  let original; try { original = JSON.parse(decoder.decode(bytes)); } catch { invalid(); }
  if (!original || original.version !== 3 || !id(original.messageID) || !id(original.senderDeviceID)
      || !kinds.has(original.kind) || !integer(original.sentAt)) invalid();
  const lifetime = original.kind === "taskCommand" ? 86_400_000 : 900_000;
  if (!Number.isSafeInteger(original.sentAt + lifetime)) invalid();
  const actionTime = original.kind === "taskCommand" ? original.taskCommand?.sentAt
    : original.kind === "approvalDecision" ? original.decision?.decidedAt
    : original.kind === "usageReset" ? original.usageReset?.requestedAt : undefined;
  if (original.sentAt > now + 60_000 || original.sentAt + lifetime <= now
      || (actionTime !== undefined && (!integer(actionTime) || actionTime > now + 60_000 || actionTime + lifetime <= now))) {
    throw new SignedEnvelopeError("signed_message_expired");
  }
  return { original, lifetime };
}

export async function signRelayEnvelope(originalBytes, identity, destination, privateKey, now = Date.now()) {
  validateIdentity(identity, now);
  if (!(originalBytes instanceof Uint8Array) || !allows(identity.role, destination)) invalid();
  const { original, lifetime } = parseOriginal(originalBytes, now);
  if (original.senderDeviceID !== identity.deviceID) invalid();
  const payload = { version: 1, roomID: identity.roomID, keyID: identity.keyID, destination,
    senderDeviceID: identity.deviceID, senderRole: identity.role, messageID: original.messageID,
    sentAt: original.sentAt, expiresAt: original.sentAt + lifetime, envelope: base64url.encode(originalBytes) };
  const header = { alg: "Ed25519", kid: await calculateJwkThumbprint(identity.jwk), typ: SIGNED_ENVELOPE_TYPE };
  const signed = await new CompactSign(encoder.encode(canonicalFlatJSON(payload))).setProtectedHeader(header).sign(privateKey);
  // Reject accidental mismatch between the supplied signer and trusted pin.
  await verifyRelayEnvelope(signed, identity, { roomID: identity.roomID, keyID: identity.keyID, destination }, now);
  return signed;
}

export async function verifyRelayEnvelope(compact, identity, expected, now = Date.now()) {
  validateIdentity(identity, now);
  if (typeof compact !== "string" || compact.length > MAX_COMPACT_BYTES || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(compact)) invalid();
  if (identity.roomID !== expected.roomID || identity.keyID !== expected.keyID || !allows(identity.role, expected.destination)) invalid();
  const parts = compact.split("."), headerBytes = decodeCanonical(parts[0], 2048);
  const signatureBytes = decodeCanonical(parts[2], 86);
  if (signatureBytes.length !== 64) invalid();
  let header; try { header = decodeProtectedHeader(compact); } catch { invalid(); }
  if (!exactKeys(header, ["alg", "kid", "typ"]) || header.alg !== "Ed25519" || header.typ !== SIGNED_ENVELOPE_TYPE
      || header.kid !== await calculateJwkThumbprint(identity.jwk)
      || !equalBytes(headerBytes, encoder.encode(canonicalFlatJSON(header)))) invalid();
  let payloadBytes;
  try { ({ payload: payloadBytes } = await compactVerify(compact, await importJWK(identity.jwk, "Ed25519"), { algorithms: ["Ed25519"] })); }
  catch { throw new SignedEnvelopeError("invalid_envelope_signature"); }
  // Compact JWS is standard; only this flat metadata profile is canonical.
  // No key, URL or algorithm is accepted from the received payload.
  if (base64url.encode(payloadBytes) !== parts[1]) invalid();
  let payload; try { payload = JSON.parse(decoder.decode(payloadBytes)); } catch { invalid(); }
  if (!exactKeys(payload, fields) || !equalBytes(payloadBytes, encoder.encode(canonicalFlatJSON(payload)))
      || payload.version !== 1 || payload.roomID !== expected.roomID || payload.keyID !== expected.keyID
      || payload.destination !== expected.destination || payload.senderDeviceID !== identity.deviceID || payload.senderRole !== identity.role
      || !id(payload.messageID) || !integer(payload.sentAt) || !integer(payload.expiresAt) || payload.expiresAt <= payload.sentAt) invalid();
  const originalBytes = decodeCanonical(payload.envelope, 1_000_000);
  const { original, lifetime } = parseOriginal(originalBytes, now);
  if (original.messageID !== payload.messageID || original.senderDeviceID !== identity.deviceID
      || original.sentAt !== payload.sentAt || original.sentAt + lifetime !== payload.expiresAt) invalid();
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", originalBytes));
  return { original, originalBytes, originalBase64URL: payload.envelope,
    originalSHA256: Array.from(digest, value => value.toString(16).padStart(2, "0")).join(""),
    senderDeviceID: identity.deviceID, senderRole: identity.role, destination: expected.destination };
}
