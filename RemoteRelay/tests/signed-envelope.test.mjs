import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { base64url, CompactSign } from "jose";
import { canonicalFlatJSON, MAX_COMPACT_BYTES, MAX_ENVELOPE_BYTES, signRelayEnvelope, verifyRelayEnvelope } from "../src/signed-envelope.mjs";
import { jwk, ownerSigner, signer, proof } from "./helpers/device-auth-fixture.mjs";

const fixture = JSON.parse(await readFile(new URL("./fixtures/swift-signed-envelope.json", import.meta.url), "utf8"));
const { identity, now, destination } = fixture;
const expected = { roomID: identity.roomID, keyID: identity.keyID, destination };
const bytes = base64url.decode(fixture.originalBase64URL), encode = value => new TextEncoder().encode(JSON.stringify(value));
const invalid = { code: "invalid_signed_envelope" };
async function resign({ header: headerChange = {}, payload: payloadChange = {}, rawPayload } = {}) {
  const [head, body] = fixture.compactJWS.split(".");
  const header = { ...JSON.parse(new TextDecoder().decode(base64url.decode(head))), ...headerChange };
  const payload = { ...JSON.parse(new TextDecoder().decode(base64url.decode(body))), ...payloadChange };
  let data = new TextEncoder().encode(canonicalFlatJSON(payload));
  if (rawPayload) data = rawPayload(data);
  return new CompactSign(data).setProtectedHeader(JSON.parse(canonicalFlatJSON(header))).sign(signer);
}

test("actual Swift message signature verifies and retains exact original Chinese emoji bytes", async () => {
  assert.equal(fixture.synthetic, true); assert.deepEqual(identity.jwk, jwk);
  const result = await verifyRelayEnvelope(fixture.compactJWS, identity, expected, now);
  assert.deepEqual(result.originalBytes, bytes);
  assert.equal(result.originalSHA256, fixture.originalSHA256);
  assert.equal(result.original.message, "中文 水獭-627🦦 / e\u0301\n\"原文\" \\ end");
});

test("independent jose signing binds identical original bytes without assuming randomized CryptoKit signatures match", async () => {
  const signed = await signRelayEnvelope(bytes, identity, destination, signer, now);
  assert.deepEqual(signed.split(".").slice(0, 2), fixture.compactJWS.split(".").slice(0, 2));
  assert.equal((await verifyRelayEnvelope(signed, identity, expected, now)).originalSHA256, fixture.originalSHA256);
});

test("reference signer refuses the wrong private key instead of returning an unusable message", async () => {
  await assert.rejects(signRelayEnvelope(bytes, identity, destination, ownerSigner, now));
});

test("tampered original text is rejected even when encrypted transport would accept the room key", async () => {
  const parts = fixture.compactJWS.split("."), payload = JSON.parse(new TextDecoder().decode(base64url.decode(parts[1])));
  payload.envelope = base64url.encode(encode({ ...JSON.parse(new TextDecoder().decode(bytes)), message: "not the original" }));
  const changed = parts[0] + "." + base64url.encode(new TextEncoder().encode(canonicalFlatJSON(payload))) + "." + parts[2];
  await assert.rejects(verifyRelayEnvelope(changed, identity, expected, now), { code: "invalid_envelope_signature" });
});

test("signed but wrong room epoch sender role message ID and deadlines cannot be substituted", async () => {
  for (const [field, value] of [["roomID", "other-room"], ["keyID", "b".repeat(32)], ["senderDeviceID", "other-phone"],
    ["senderRole", "mac"], ["destination", "watch"], ["messageID", "other-message"], ["sentAt", now + 1],
    ["expiresAt", now + 900_001], ["version", 2]]) {
    await assert.rejects(verifyRelayEnvelope(await resign({ payload: { [field]: value } }), identity, expected, now), invalid, field);
  }
});

test("trusted context, not an asserted payload or header, selects scope and pinned identity", async () => {
  for (const changed of [{ ...expected, roomID: "other-room" }, { ...expected, keyID: "b".repeat(32) }, { ...expected, destination: "phone" }]) {
    await assert.rejects(verifyRelayEnvelope(fixture.compactJWS, identity, changed, now), invalid);
  }
  await assert.rejects(verifyRelayEnvelope(fixture.compactJWS, { ...identity, deviceID: "other-phone" }, expected, now), invalid);
  await assert.rejects(verifyRelayEnvelope(fixture.compactJWS, { ...identity, jwk: { ...jwk, x: base64url.encode(new Uint8Array(32)) } }, expected, now), invalid);
});

test("connection DPoP, generic algorithm, embedded private key and unknown headers are not message signatures", async () => {
  for (const header of [{ typ: "dpop+jwt" }, { alg: "EdDSA" }, { jwk: { ...jwk, d: "private" } }, { jku: "https://evil.example/key" }]) {
    await assert.rejects(verifyRelayEnvelope(await resign({ header }), identity, expected, now), invalid);
  }
  await assert.rejects(verifyRelayEnvelope(await proof(), identity, expected, now), invalid);
});

test("unknown duplicate and noncanonical flat metadata is rejected despite a correct signature", async () => {
  await assert.rejects(verifyRelayEnvelope(await resign({ payload: { unexpected: true } }), identity, expected, now), invalid);
  const duplicate = await resign({ rawPayload: data => new TextEncoder().encode("{\"version\":1," + new TextDecoder().decode(data).slice(1)) });
  await assert.rejects(verifyRelayEnvelope(duplicate, identity, expected, now), invalid);
  const whitespace = await resign({ rawPayload: data => new TextEncoder().encode(" " + new TextDecoder().decode(data)) });
  await assert.rejects(verifyRelayEnvelope(whitespace, identity, expected, now), invalid);
});

test("noncanonical original encoding invalid UTF8 and malformed original cannot masquerade as intact bytes", async () => {
  for (const envelope of [fixture.originalBase64URL + "=", base64url.encode(new Uint8Array([255, 254])), base64url.encode(encode({ not: "an envelope" }))]) {
    await assert.rejects(verifyRelayEnvelope(await resign({ payload: { envelope } }), identity, expected, now), invalid);
  }
});

test("changed original ID sender version or timestamp cannot disagree with the signed metadata", async () => {
  const original = JSON.parse(new TextDecoder().decode(bytes));
  for (const change of [{ messageID: "changed" }, { senderDeviceID: "another" }, { version: 2 }, { sentAt: now + 1 }]) {
    const envelope = base64url.encode(encode({ ...original, ...change }));
    await assert.rejects(verifyRelayEnvelope(await resign({ payload: { envelope } }), identity, expected, now), invalid);
  }
});

test("expired or revoked identity cannot receive retrospective authorization", async () => {
  for (const pin of [{ ...identity, expiresAt: now }, { ...identity, revokedAt: now }]) {
    await assert.rejects(verifyRelayEnvelope(fixture.compactJWS, pin, expected, now), { code: "signed_identity_expired" });
  }
  for (const pin of [{ ...identity, jwk: { ...jwk, d: "private" } }, { ...identity, role: "admin" }, { ...identity, unexpected: true }]) {
    await assert.rejects(verifyRelayEnvelope(fixture.compactJWS, pin, expected, now), invalid);
  }
});

test("old message, future message and stale original action cannot be refreshed by a new wrapper", async () => {
  await assert.rejects(verifyRelayEnvelope(fixture.compactJWS, identity, expected, now + 900_000), { code: "signed_message_expired" });
  const original = JSON.parse(new TextDecoder().decode(bytes));
  for (const changed of [{ ...original, sentAt: now + 60_001 }, { ...original, kind: "taskCommand", taskCommand: { sentAt: now - 86_400_001 } }]) {
    await assert.rejects(signRelayEnvelope(encode(changed), identity, destination, signer, now), { code: "signed_message_expired" });
  }
});

test("original bytes larger than the bounded profile and oversized compact data are rejected", async () => {
  await assert.rejects(signRelayEnvelope(new Uint8Array(MAX_ENVELOPE_BYTES + 1), identity, destination, signer, now), { code: "signed_envelope_too_large" });
  await assert.rejects(verifyRelayEnvelope("a".repeat(MAX_COMPACT_BYTES + 1), identity, expected, now), invalid);
  for (const compact of ["", "one.two", "a.b.c.d", fixture.compactJWS + "=", "中文.a.b"]) {
    await assert.rejects(verifyRelayEnvelope(compact, identity, expected, now), invalid);
  }
});

test("near-budget envelope signs and verifies without silently truncating the original", async () => {
  const original = JSON.parse(new TextDecoder().decode(bytes)); original.message = "a".repeat(740_000);
  const input = encode(original), signed = await signRelayEnvelope(input, identity, destination, signer, now);
  const result = await verifyRelayEnvelope(signed, identity, expected, now);
  assert.deepEqual(result.originalBytes, input); assert.equal(result.original.message.length, 740_000);
});

test("mobile pins cannot sign into another mobile mailbox or the shared snapshot", async () => {
  for (const target of ["phone", "watch", "snapshot", "unknown"]) await assert.rejects(signRelayEnvelope(bytes, identity, target, signer, now), invalid);
});

test("Node-generated reverse interoperability vector uses only public synthetic material", async () => {
  const path = process.env.CODEX_SIGNED_ENVELOPE_NODE_QA_OUTPUT;
  if (!path) return;
  assert.match(path, /^\/private\/tmp\/relay-signed-interop\.[A-Za-z0-9]+\/node-envelope.json$/);
  const original = { version: 3, messageID: "qa-node-original", sentAt: now, kind: "hello", senderDeviceID: identity.deviceID,
    message: "Node→Swift：松果-819🐿️\nnext" };
  const compactJWS = await signRelayEnvelope(encode(original), identity, destination, signer, now);
  const verified = await verifyRelayEnvelope(compactJWS, identity, expected, now);
  await writeFile(path, JSON.stringify({ synthetic: true, compactJWS, originalSHA256: verified.originalSHA256,
    originalBase64URL: verified.originalBase64URL }), { flag: "wx", mode: 0o600 });
});
