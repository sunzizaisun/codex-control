// SQLite-backed Durable Object KV values are limited to 2 MB including the
// key. Reserve space for metadata; never buffer a claimed 16 MiB packet.
export const MAX_SEALED_LENGTH = 1_900_000;
export const MAX_PACKET_JSON_BYTES = MAX_SEALED_LENGTH + 2048;

export class PacketReadError extends Error {
  constructor(status) { super(status === 413 ? "packet too large" : "invalid packet"); this.status = status; }
}

export function isRelayPacket(packet) {
  if (!packet || typeof packet !== "object" || Array.isArray(packet)) return false;
  if (typeof packet.id !== "string" || !/^[A-Za-z0-9_-]{1,160}$/.test(packet.id)) return false;
  if (!Number.isSafeInteger(packet.sentAt) || packet.sentAt < 0) return false;
  if (packet.expiresAt !== undefined && (!Number.isSafeInteger(packet.expiresAt) || packet.expiresAt < packet.sentAt)) return false;
  // Read compatibility: don't delete a preexisting value solely because the
  // new admission limit is smaller. New writes are bounded separately below.
  return typeof packet.sealed === "string" && packet.sealed.length > 0
    && packet.sealed.length <= 16 * 1024 * 1024
    && /^[A-Za-z0-9+/]*={0,2}$/.test(packet.sealed);
}

export async function readPacket(request, context = undefined) {
  return (await readPacketRequest(request, context)).packet;
}

// Same bounded parser for old/new transports. The v3 caller also needs the
// actually received bytes for its private body-bound proof, not a re-encoding.
export async function readPacketRequest(request, context = undefined) {
  if (Number(request.headers.get("content-length")) > MAX_PACKET_JSON_BYTES) throw new PacketReadError(413);
  if (!request.body) throw new PacketReadError(400);
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_PACKET_JSON_BYTES) {
        await reader.cancel();
        throw new PacketReadError(413);
      }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    const packet = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    if (typeof packet?.sealed === "string" && packet.sealed.length > MAX_SEALED_LENGTH) throw new PacketReadError(413);
    if (!isRelayPacket(packet)) throw new PacketReadError(400);
    // Ignore no unknown fields: reject them, so data outside the encrypted
    // payload cannot accidentally become stored plaintext/debug material.
    const keys = context ? ["version", "keyID", "destination", "id", "sentAt", "expiresAt", "sealed"] : ["id", "sentAt", "expiresAt", "sealed"];
    if (Object.keys(packet).some(key => !keys.includes(key))) throw new PacketReadError(400);
    if (context && (![2, 3].includes(context.version ?? 2) || packet.version !== (context.version ?? 2) || packet.keyID !== context.keyID
      || packet.destination !== context.destination || !Number.isSafeInteger(packet.expiresAt))) throw new PacketReadError(400);
    return { packet, bytes };
  } catch (error) {
    if (error instanceof PacketReadError) throw error;
    throw new PacketReadError(400);
  } finally { reader.releaseLock(); }
}

export function isExpired(packet, lifetimeMs, now = Date.now()) {
  return !Number.isSafeInteger(packet?.sentAt) || packet.sentAt > now + 60_000 || now >= packet.sentAt + lifetimeMs;
}

export function isMailboxPacketExpired(packet, now = Date.now()) {
  if (isExpired(packet, 24 * 60 * 60 * 1000, now)) return true;
  return now >= (packet.expiresAt ?? packet.sentAt + 15 * 60 * 1000);
}

export function constantTimeEqual(a, b) {
  if (!a || !b) return false;
  const encoder = new TextEncoder();
  const left = encoder.encode(a), right = encoder.encode(b);
  if (left.byteLength !== right.byteLength) return false;
  return crypto.subtle.timingSafeEqual(left, right);
}
