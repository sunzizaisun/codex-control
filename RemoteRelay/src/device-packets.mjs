import { bodyHash, DeviceAuthError } from "./device-auth.mjs";
import { MAX_SEALED_LENGTH, PacketReadError, readPacketRequest } from "./packet.mjs";

export function validDevicePacket(packet, context, now, checkExpiry = true) {
  if (!packet || typeof packet !== "object" || Array.isArray(packet)
      || Object.keys(packet).sort().join(",") !== "destination,expiresAt,id,keyID,sealed,sentAt,version"
      || packet.version !== 3 || packet.keyID !== context.keyID || packet.destination !== context.destination
      || typeof packet.id !== "string" || !/^[A-Za-z0-9_-]{1,160}$/.test(packet.id)
      || !Number.isSafeInteger(packet.sentAt) || packet.sentAt < 0
      || !Number.isSafeInteger(packet.expiresAt) || packet.expiresAt <= packet.sentAt
      || packet.expiresAt > packet.sentAt + 86_400_000
      || typeof packet.sealed !== "string" || packet.sealed.length < 40 || packet.sealed.length > MAX_SEALED_LENGTH
      || !/^[A-Za-z0-9+/]*={0,2}$/.test(packet.sealed)) return false;
  try { if (btoa(atob(packet.sealed)) !== packet.sealed) return false; } catch { return false; }
  return !checkExpiry || (packet.sentAt <= now + 60_000 && packet.expiresAt > now
    && (packet.destination !== "snapshot" || packet.sentAt + 300_000 > now));
}

export function packetContentBytes(packet) {
  return new TextEncoder().encode(JSON.stringify([packet.version, packet.keyID, packet.destination,
    packet.id, packet.sentAt, packet.expiresAt, packet.sealed]));
}
export async function readDevicePacket(request, context, now) {
  const { packet, bytes } = await readPacketRequest(request, { ...context, version: 3 });
  if (!validDevicePacket(packet, context, now)) throw new PacketReadError(400);
  return { packet, bodyDigest: await bodyHash(bytes), packetDigest: await bodyHash(packetContentBytes(packet)) };
}

export const sequenceText = value => {
  if (!Number.isSafeInteger(value) || value < 1) throw new DeviceAuthError("device_relay_state_unavailable", 503);
  return String(value).padStart(16, "0");
};
