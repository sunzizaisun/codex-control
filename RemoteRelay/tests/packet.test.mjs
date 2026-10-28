import { test } from "node:test";
import assert from "node:assert/strict";
import { readPacket, MAX_PACKET_JSON_BYTES, MAX_SEALED_LENGTH, isRelayPacket, isMailboxPacketExpired, constantTimeEqual } from "../src/packet.mjs";

const fixture = { id: "message-1", sentAt: 100_000, sealed: "YQ==" };
const request = body => new Request("https://fixture.invalid", { method: "POST", body });

test("valid packet survives byte-for-byte and invalid IDs are rejected", async () => {
  assert.deepEqual(await readPacket(request(JSON.stringify(fixture))), fixture);
  assert.equal(isRelayPacket({ ...fixture, id: "../other" }), false);
  assert.equal(isRelayPacket({ ...fixture, sentAt: Number.MAX_VALUE }), false);
});
test("unknown plaintext fields and malformed UTF-8 are rejected", async () => {
  await assert.rejects(readPacket(request(JSON.stringify({ ...fixture, debug: "private" }))), { status: 400 });
  await assert.rejects(readPacket(request(new Uint8Array([0xff]))), { status: 400 });
});
test("actual streaming size is bounded without content-length", async () => {
  const stream = new ReadableStream({ start(controller) {
    controller.enqueue(new Uint8Array(MAX_PACKET_JSON_BYTES + 1)); controller.close();
  } });
  await assert.rejects(readPacket(new Request("https://fixture.invalid", { method: "POST", body: stream, duplex: "half" })), { status: 413 });
});
test("oversized sealed payload returns 413 before storage, not storage 500", async () => {
  await assert.rejects(readPacket(request(JSON.stringify({ ...fixture, sealed: "a".repeat(MAX_SEALED_LENGTH + 1) }))), { status: 413 });
});
test("deadline cannot extend beyond 24 hours or originate in the future", () => {
  assert.equal(isMailboxPacketExpired({ ...fixture, expiresAt: 999_999_999 }, 100_000 + 86_400_000), true);
  assert.equal(isMailboxPacketExpired(fixture, 100_000 + 900_000), true);
  assert.equal(isMailboxPacketExpired(fixture, 100_001), false);
  assert.equal(isMailboxPacketExpired({ ...fixture, sentAt: 1_000_000 }, 100_000), true);
});
test("Unicode header with equal character count cannot throw in timingSafeEqual", () => {
  assert.equal(constantTimeEqual("é", "a"), false);
  assert.equal(constantTimeEqual("", ""), false);
});
