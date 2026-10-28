import { test } from "node:test";
import assert from "node:assert/strict";
import { timingSafeEqual } from "node:crypto";
import { authorizeRelayV2, relayV2Records, validRelayRoomID } from "../src/auth-v2.mjs";
import { readPacket } from "../src/packet.mjs";
import { relayV2Credentials, relayV2ServerRecord, sealRelayV2, openRelayV2 } from "../../scripts/lib/relay-v2-credentials.mjs";

// Workers provides this extension; Node's test runner uses its native equal
// length constant-time comparator as the local equivalent.
if (!crypto.subtle.timingSafeEqual) crypto.subtle.timingSafeEqual = (a, b) => timingSafeEqual(Buffer.from(a), Buffer.from(b));
const room = "qa-room", credentials = relayV2Credentials("fixture-only-".repeat(4), room);
const record = relayV2ServerRecord(credentials, room), registry = JSON.stringify([record]);

test("server authentication is scoped to room and key ID", () => {
  assert.deepEqual(authorizeRelayV2(registry, room, credentials.keyID, credentials.authToken), { configured: true, authorized: true });
  for (const [r, k, t] of [["other-room", credentials.keyID, credentials.authToken], [room, "0".repeat(32), credentials.authToken], [room, credentials.keyID, "bad"]]) {
    assert.equal(authorizeRelayV2(registry, r, k, t).authorized, false);
  }
});
test("server registry rejects accidental device key uploads and duplicate records", () => {
  assert.equal(relayV2Records(JSON.stringify([{ ...record, encryptionKey: "never-upload" }])), null);
  assert.equal(relayV2Records(JSON.stringify([record, record])), null);
  assert.equal(relayV2Records("broken"), null);
  assert.deepEqual(Object.keys(record).sort(), ["authToken", "keyID", "roomID"]);
});
test("legacy room names cannot impersonate the secure Durable Object namespace", () => {
  assert.equal(validRelayRoomID(room), true);
  assert.equal(validRelayRoomID(`v2:${room}:${credentials.keyID}`), false);
  for (const invalid of ["../room", "room/path", "room\n", "%3A", ""]) assert.equal(validRelayRoomID(invalid), false);
});
test("server token cannot decrypt a packet even with the original authenticated routing", () => {
  const envelope = { version: 3, messageID: "fixture-message", sentAt: Date.now(), kind: "taskCommand", senderDeviceID: "watch", message: "海狸-428🍁" };
  const packet = sealRelayV2(envelope, credentials, room, "mac");
  assert.deepEqual(openRelayV2(packet, credentials, room, "mac"), envelope);
  assert.throws(() => openRelayV2(packet, { ...credentials, encryptionKey: Buffer.from(credentials.authToken, "base64") }, room, "mac"));
  assert.throws(() => openRelayV2({ ...packet, expiresAt: packet.expiresAt + 1 }, credentials, room, "mac"));
  assert.throws(() => openRelayV2(packet, credentials, "other-room", "mac"));
});
test("secure packet admission refuses legacy, wrong target and wrong key ID", async () => {
  const envelope = { version: 3, messageID: "fixture-message", sentAt: Date.now(), kind: "taskCommand", senderDeviceID: "watch" };
  const packet = sealRelayV2(envelope, credentials, room, "mac");
  const req = value => new Request("https://fixture.invalid", { method: "POST", body: JSON.stringify(value) });
  const context = { destination: "mac", keyID: credentials.keyID };
  assert.deepEqual(await readPacket(req(packet), context), packet);
  for (const changed of [{ ...packet, version: 1 }, { ...packet, destination: "phone" }, { ...packet, keyID: "0".repeat(32) }]) {
    await assert.rejects(readPacket(req(changed), context), { status: 400 });
  }
  const { version, keyID, destination, ...legacy } = packet;
  await assert.rejects(readPacket(req(legacy), context), { status: 400 });
});
