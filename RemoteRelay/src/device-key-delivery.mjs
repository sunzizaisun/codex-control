import { calculateJwkThumbprint } from "jose";
import { authorizeDevice, base64URL, bodyHash, DeviceAuthError, requireUnrevokedDevice, roleAllows, verifyDeviceProof } from "./device-auth.mjs";
import { enrolledDeviceRecords } from "./device-enrollment.mjs";
import { readDeviceJSON } from "./device-json.mjs";
import { deviceAdmission, deviceJSON, DEVICE_PROTOCOL_HEADER } from "./device-routing.mjs";

const id = value => typeof value === "string" && /^[A-Za-z0-9_-]{1,160}$/.test(value);
const integer = value => Number.isSafeInteger(value) && value >= 0;
const exact = (value, fields) => value && typeof value === "object" && !Array.isArray(value)
  && Object.keys(value).sort().join(",") === [...fields].sort().join(",");
const fail = (code, status = 503) => { throw new DeviceAuthError(code, status); };
const decode = (text, maximum = 12_000) => {
  if (typeof text !== "string" || !/^[A-Za-z0-9_-]+$/.test(text) || text.length > maximum) return undefined;
  try {
    const binary = atob(text.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - text.length % 4) % 4));
    const bytes = Uint8Array.from(binary, value => value.charCodeAt(0));
    return base64URL(bytes) === text ? bytes : undefined;
  } catch { return undefined; }
};
const digest = value => decode(value, 43)?.length === 32;
const prefix = context => `device-key:${context.roomID}:${context.keyID}:`;
const slot = (context, deviceID) => prefix(context) + deviceID;
const fields = ["version", "suite", "phase", "roomID", "keyID", "invitationID", "ownerID", "deviceID", "role", "requestID", "expiresAt", "enc", "sealed"];
const headerFields = ["roomID", "keyID", "invitationID", "ownerID", "deviceID", "role", "requestID", "expiresAt", "suite", "version"];
const canonical = value => JSON.stringify(Object.fromEntries(Object.keys(value).sort().map(key => [key, value[key]])));

export function keyDeliveryPacket(value, context, phase) {
  return exact(value, phase === "response" ? [...fields, "requestDigest"] : fields)
    && value.version === 1 && value.suite === "X25519-HKDF-SHA256-CHACHA20POLY1305" && value.phase === phase
    && value.roomID === context.roomID && value.keyID === context.keyID
    && [value.invitationID, value.ownerID, value.deviceID, value.requestID].every(id)
    && value.ownerID !== value.deviceID && ["phone", "watch"].includes(value.role)
    && integer(value.expiresAt) && value.expiresAt > 0 && decode(value.enc, 43)?.length === 32
    && (decode(value.sealed, 6000)?.length ?? 0) >= 16
    && (phase !== "response" || digest(value.requestDigest));
}
function packetBytes(bytes, context, phase) {
  if (!(bytes instanceof Uint8Array) || bytes.length > 8192) fail("key_delivery_state_unavailable");
  let text, value;
  try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); value = JSON.parse(text); } catch { fail("key_delivery_state_unavailable"); }
  if (!keyDeliveryPacket(value, context, phase) || canonical(value) !== text) fail("key_delivery_state_unavailable");
  return value;
}
async function state(row, context, key) {
  if (!exact(row, ["version", "deviceID", "ownerID", "role", "requesterThumbprint", "ownerThumbprint", "requestBytes", "requestDigest", "responseBytes", "responseDigest", "expiresAt"])
      || row.version !== 1 || !id(row.deviceID) || !id(row.ownerID) || slot(context, row.deviceID) !== key
      || !["phone", "watch"].includes(row.role) || !digest(row.requesterThumbprint) || !digest(row.ownerThumbprint)
      || !digest(row.requestDigest) || !integer(row.expiresAt)
      || (row.responseBytes === null) !== (row.responseDigest === null)) fail("key_delivery_state_unavailable");
  const requestBytes = decode(row.requestBytes), responseBytes = row.responseBytes === null ? undefined : decode(row.responseBytes);
  if (!requestBytes || (row.responseBytes !== null && (!responseBytes || !digest(row.responseDigest)))
      || await bodyHash(requestBytes) !== row.requestDigest) fail("key_delivery_state_unavailable");
  const request = packetBytes(requestBytes, context, "request");
  if (request.deviceID !== row.deviceID || request.ownerID !== row.ownerID || request.role !== row.role || request.expiresAt !== row.expiresAt) fail("key_delivery_state_unavailable");
  if (responseBytes) {
    const response = packetBytes(responseBytes, context, "response");
    if (await bodyHash(responseBytes) !== row.responseDigest || response.requestDigest !== row.requestDigest
        || headerFields.some(field => response[field] !== request[field])) fail("key_delivery_state_unavailable");
  }
  return { request, requestBytes, responseBytes };
}
const packetHTTP = bytes => bytes ? new Response(bytes, { headers: {
  "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", [DEVICE_PROTOCOL_HEADER]: "3",
} }) : deviceJSON(undefined, 204);
export const keyDeliveryResource = resource => ["devices/key-requests", "devices/me/key-request", "devices/me/room-key"].includes(resource)
  || /^devices\/key-responses\/[A-Za-z0-9_-]{1,160}$/.test(resource);

// Actual v3 HTTP dispatch delegates here. The relay never has the QR-only
// PSK or HPKE private keys and never decrypts a requested/delivered room key.
// One immutable request/response per device grant is retained, including after
// expiry, so cleanup cannot renew an old pairing. Registry capacity bounds it.
export async function handleKeyDelivery(request, context, roots, storage, clock = Date.now) {
  const records = await enrolledDeviceRecords(storage, roots, context), raw = JSON.stringify(records);
  const write = request.method === "POST";
  if (write) {
    const verified = await verifyDeviceProof(request, { ...context, requireBodyDigest: true }, raw, clock());
    if (!roleAllows(verified.principal.role, request.method, context.resource)) fail("device_role_forbidden", 403);
  } else if (request.body !== null) fail("unexpected_device_body", 400);
  const body = write ? await readDeviceJSON(request, 8192, "key_delivery") : undefined;
  const phase = context.resource === "devices/me/key-request" ? "request" : "response";
  if (body && (!keyDeliveryPacket(body.value, context, phase)
      || canonical(body.value) !== new TextDecoder().decode(body.bytes))) fail("invalid_key_delivery_packet", 400);
  const authorization = await authorizeDevice(request, { ...context, ...(body ? { bodyDigest: body.bodyDigest } : {}) }, raw, storage, clock);
  if (!authorization.authorized) return deviceAdmission(authorization);
  const principal = authorization.principal;
  const thumbprints = new Map(await Promise.all(records.map(async peer => [peer.deviceID, await calculateJwkThumbprint(peer.jwk)])));
  async function active(transaction, deviceID, role) {
    const peer = records.find(value => value.deviceID === deviceID);
    if (!peer || (role && peer.role !== role)) fail("key_delivery_peer_unavailable", 401);
    await requireUnrevokedDevice(transaction, peer);
    if (peer.expiresAt <= clock() || peer.revokedAt <= clock()) fail("key_delivery_peer_unavailable", 401);
    return peer;
  }
  async function pair(transaction, row) {
    const recipient = await active(transaction, row.deviceID, row.role), owner = await active(transaction, row.ownerID, "mac");
    if (thumbprints.get(recipient.deviceID) !== row.requesterThumbprint || thumbprints.get(owner.deviceID) !== row.ownerThumbprint) {
      fail("key_delivery_peer_unavailable", 401);
    }
    const current = clock();
    if (recipient.expiresAt <= current || owner.expiresAt <= current) fail("key_delivery_peer_unavailable", 401);
  }
  const result = await storage.transaction(async transaction => {
    await active(transaction, principal.deviceID, principal.role);
    if (context.resource === "devices/key-requests") {
      const rows = await transaction.list({ prefix: prefix(context), limit: 65 });
      if (rows.size > 64) fail("key_delivery_state_unavailable");
      const requests = [];
      for (const [key, row] of rows) {
        const saved = await state(row, context, key);
        if (row.ownerID !== principal.deviceID || row.expiresAt <= clock() || saved.responseBytes) continue;
        try { await pair(transaction, row); }
        catch (error) { if (error instanceof DeviceAuthError && error.status === 401) continue; throw error; }
        requests.push({ packet: base64URL(saved.requestBytes), expiresAt: row.expiresAt });
      }
      await active(transaction, principal.deviceID, principal.role);
      const capturedAt = clock();
      return { kind: "list", value: { requests: requests.filter(row => row.expiresAt > capturedAt)
        .map(({ packet }) => ({ packet })), capturedAt } };
    }
    const target = context.resource.startsWith("devices/key-responses/") ? context.resource.split("/")[2] : principal.deviceID;
    const key = slot(context, target), existing = await transaction.get(key);
    let saved;
    if (existing !== undefined) saved = await state(existing, context, key);
    await active(transaction, principal.deviceID, principal.role);
    if (context.resource === "devices/me/key-request" && write) {
      const packet = body.value;
      if (packet.deviceID !== principal.deviceID || packet.role !== principal.role) fail("key_delivery_identity_mismatch", 403);
      const recipient = await active(transaction, principal.deviceID, principal.role), owner = await active(transaction, packet.ownerID, "mac");
      if (packet.expiresAt <= clock() || packet.expiresAt > clock() + 420_000 || packet.expiresAt > recipient.expiresAt) fail("key_delivery_expired", 410);
      if (existing !== undefined) {
        await pair(transaction, existing);
        if (existing.requestDigest !== body.bodyDigest) fail("key_delivery_conflict", 409);
        return { kind: "json", value: { stored: true, duplicate: true, requestID: packet.requestID, digest: body.bodyDigest } };
      }
      const rows = await transaction.list({ prefix: prefix(context), limit: 65 });
      if (rows.size > 64) fail("key_delivery_state_unavailable");
      if (rows.size >= 64) fail("key_delivery_capacity", 429);
      await active(transaction, principal.deviceID, principal.role); await active(transaction, owner.deviceID, "mac");
      if (packet.expiresAt <= clock()) fail("key_delivery_expired", 410);
      const row = { version: 1, deviceID: principal.deviceID, ownerID: owner.deviceID, role: principal.role,
        requesterThumbprint: thumbprints.get(principal.deviceID), ownerThumbprint: thumbprints.get(owner.deviceID),
        requestBytes: base64URL(body.bytes), requestDigest: body.bodyDigest, responseBytes: null, responseDigest: null, expiresAt: packet.expiresAt };
      await transaction.put(key, row);
      await pair(transaction, row);
      if (packet.expiresAt <= clock()) fail("key_delivery_expired", 410);
      return { kind: "json", value: { stored: true, duplicate: false, requestID: packet.requestID, digest: body.bodyDigest } };
    }
    if (!existing) {
      if (write) fail("key_delivery_request_not_found", 404);
      return { kind: "packet", bytes: undefined };
    }
    if (principal.role === "mac" && principal.deviceID !== existing.ownerID) fail("key_delivery_owner_mismatch", 403);
    await pair(transaction, existing);
    if (existing.expiresAt <= clock()) {
      if (write) fail("key_delivery_expired", 410);
      return { kind: "packet", bytes: undefined };
    }
    if (write) {
      if (body.value.requestDigest !== existing.requestDigest || headerFields.some(field => body.value[field] !== saved.request[field])) fail("key_delivery_conflict", 409);
      if (existing.responseBytes !== null) {
        if (existing.responseDigest !== body.bodyDigest) fail("key_delivery_conflict", 409);
        return { kind: "json", value: { stored: true, duplicate: true, requestID: body.value.requestID, digest: body.bodyDigest } };
      }
      await active(transaction, principal.deviceID, principal.role); await pair(transaction, existing);
      if (existing.expiresAt <= clock()) fail("key_delivery_expired", 410);
      await transaction.put(key, { ...existing, responseBytes: base64URL(body.bytes), responseDigest: body.bodyDigest });
      await pair(transaction, existing);
      if (existing.expiresAt <= clock()) fail("key_delivery_expired", 410);
      return { kind: "json", value: { stored: true, duplicate: false, requestID: body.value.requestID, digest: body.bodyDigest } };
    }
    const bytes = context.resource === "devices/me/key-request" ? saved.requestBytes : saved.responseBytes;
    await active(transaction, principal.deviceID, principal.role); await pair(transaction, existing);
    if (existing.expiresAt <= clock()) return { kind: "packet", bytes: undefined };
    return { kind: "packet", bytes };
  });
  return result.kind === "packet" ? packetHTTP(result.bytes) : deviceJSON(result.value);
}
