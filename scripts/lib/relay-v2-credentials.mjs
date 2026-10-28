import { createHash, hkdfSync, createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

export function relayV2Credentials(secret, roomID) {
  if (Buffer.byteLength(secret) < 32 || !/^[A-Za-z0-9_-]{1,160}$/.test(roomID)) throw new Error("Invalid relay migration input");
  const salt = Buffer.from(`codex-control/relay/v2/${roomID}`);
  const derive = context => Buffer.from(hkdfSync("sha256", Buffer.from(secret), salt, Buffer.from(context), 32));
  const encryptionKey = derive("device-only-encryption");
  return { authToken: derive("server-authentication").toString("base64"), encryptionKey,
    keyID: createHash("sha256").update(encryptionKey).digest("hex").slice(0, 32) };
}

export function relayV2ServerRecord(credentials, roomID) {
  return { roomID, keyID: credentials.keyID, authToken: credentials.authToken };
}

function aad(packet, roomID) {
  return Buffer.from(["codex-control/relay", "2", packet.keyID, roomID, packet.destination,
    packet.id, String(packet.sentAt), String(packet.expiresAt)].join("\n"));
}

export function sealRelayV2(envelope, credentials, roomID, destination) {
  const packet = { version: 2, keyID: credentials.keyID, destination, id: envelope.messageID,
    sentAt: envelope.sentAt, expiresAt: envelope.sentAt + (envelope.kind === "taskCommand" ? 86_400_000 : 900_000) };
  const nonce = randomBytes(12), cipher = createCipheriv("aes-256-gcm", credentials.encryptionKey, nonce);
  cipher.setAAD(aad(packet, roomID));
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(envelope), "utf8"), cipher.final()]);
  return { ...packet, sealed: Buffer.concat([nonce, ciphertext, cipher.getAuthTag()]).toString("base64") };
}

export function openRelayV2(packet, credentials, roomID, destination) {
  if (packet.version !== 2 || packet.keyID !== credentials.keyID || packet.destination !== destination) throw new Error("Invalid secure packet");
  const bytes = Buffer.from(packet.sealed, "base64");
  const decipher = createDecipheriv("aes-256-gcm", credentials.encryptionKey, bytes.subarray(0, 12));
  decipher.setAAD(aad(packet, roomID)); decipher.setAuthTag(bytes.subarray(-16));
  const plaintext = Buffer.concat([decipher.update(bytes.subarray(12, -16)), decipher.final()]);
  return JSON.parse(plaintext.toString("utf8"));
}
