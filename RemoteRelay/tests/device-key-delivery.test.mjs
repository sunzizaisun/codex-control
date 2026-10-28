import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { BODY_HASH_CLAIM, bodyHash, roleAllows, tokenHash } from "../src/device-auth.mjs";
import { DeviceRelayOperations } from "../src/device-relay.mjs";
import { forwardDeviceRequest } from "../src/device-routing.mjs";
import { context, keys, MemoryJournal, nonce, nonceRecord, now, ownerJWK, ownerRecord, ownerSigner, ownerToken, proof, record, request, token, url } from "./helpers/device-auth-fixture.mjs";

const canonical = value => JSON.stringify(Object.fromEntries(Object.keys(value).sort().map(key => [key, value[key]])));
const utf8 = value => new TextEncoder().encode(value);
const opaque = { version: 1, suite: "X25519-HKDF-SHA256-CHACHA20POLY1305", phase: "request", roomID: "qa", keyID: record.keyID,
  invitationID: "synthetic-pairing", ownerID: ownerRecord.deviceID, deviceID: record.deviceID, role: "phone",
  requestID: "synthetic-key-request", expiresAt: now + 60_000, enc: Buffer.alloc(32, 7).toString("base64url"), sealed: Buffer.alloc(48, 9).toString("base64url") };
const slot = `device-key:qa:${record.keyID}:${record.deviceID}`;
class Journal extends MemoryJournal {
  async get(key) { return structuredClone(this.persisted.get(key)); }
  async list({ prefix, limit = 1000 }) { return new Map([...this.persisted].filter(([key]) => key.startsWith(prefix)).sort(([a], [b]) => a.localeCompare(b)).slice(0, limit)); }
}
function environment({ nonces = true, clock = () => now, records = [ownerRecord, record] } = {}) {
  const storage = new Journal(nonces ? new Map(records.map(peer => [keys.nonce(peer.deviceID, peer.roomID, peer.keyID), nonceRecord(nonce, clock() + 120_000)])) : new Map());
  const ctx = { storage, getWebSockets: () => [] }, env = { RELAY_DEVICE_ROOTS_V3: JSON.stringify(records) };
  const operations = new DeviceRelayOperations(ctx, env, clock);
  env.RELAY_ROOMS = { idFromName: value => value, get: () => ({ fetch: value => operations.handle(value) }) };
  return { operations, storage, env };
}
async function signed(resource, { owner = false, method = "GET", body, raw, claims = {}, headers = {} } = {}) {
  const encoded = raw ?? (body === undefined ? undefined : canonical(body)), uri = url(resource);
  const signature = await proof({ uri, method, nonce, ...(owner ? { key: ownerSigner, header: { jwk: ownerJWK } } : {}),
    claims: { ...(owner ? { ath: await tokenHash(ownerToken) } : {}), ...(encoded === undefined ? {} : { [BODY_HASH_CLAIM]: await bodyHash(utf8(encoded)) }), ...claims } });
  return request(signature, { uri, method, accessToken: owner ? ownerToken : token, body: encoded,
    headers: { "X-Codex-Relay-Key-ID": record.keyID, "X-Codex-Relay-Protocol": "3", "X-Codex-Relay-Room": record.roomID, ...headers } });
}
async function upload(e, value = opaque, options = {}) { return e.operations.handle(await signed("devices/me/key-request", { method: "POST", body: value, ...options })); }
async function responsePacket(value = opaque) { return { ...value, phase: "response", requestDigest: await bodyHash(utf8(canonical(value))) }; }

test("key delivery role matrix does not give mobile devices owner access", () => {
  for (const role of ["mac", "phone", "watch"]) {
    assert.equal(roleAllows(role, "GET", "devices/key-requests"), role === "mac");
    assert.equal(roleAllows(role, "POST", "devices/me/key-request"), role !== "mac");
    assert.equal(roleAllows(role, "GET", "devices/me/room-key"), role !== "mac");
    assert.equal(roleAllows(role, "POST", "devices/key-responses/qa-phone"), role === "mac");
    assert.equal(roleAllows(role, "GET", "devices/key-responses/qa-phone"), role === "mac");
    assert.equal(roleAllows(role, "DELETE", "devices/key-responses/qa-phone"), false);
  }
});

test("key delivery nonce challenge stores no opaque request and returns real protocol headers", async () => {
  const e = environment({ nonces: false }), result = await upload(e);
  assert.equal(result.status, 401); assert.equal((await result.json()).error, "use_dpop_nonce");
  assert.equal(result.headers.get("X-Codex-Relay-Device-Protocol"), "3"); assert(result.headers.get("DPoP-Nonce"));
  assert(!e.storage.persisted.has(slot));
});

test("opaque key delivery retains exact bytes through own query, owner list, reply and query", async () => {
  const e = environment();
  assert.equal((await e.operations.handle(await signed("devices/me/key-request"))).status, 204);
  assert.equal((await upload(e)).status, 200);
  assert.equal(await (await e.operations.handle(await signed("devices/me/key-request"))).text(), canonical(opaque));
  const list = await (await e.operations.handle(await signed("devices/key-requests", { owner: true }))).json();
  assert.equal(list.requests.length, 1); assert.equal(Buffer.from(list.requests[0].packet, "base64url").toString(), canonical(opaque));
  assert.equal((await e.operations.handle(await signed("devices/me/room-key"))).status, 204);
  const reply = await responsePacket();
  const stored = await (await e.operations.handle(await signed("devices/key-responses/qa-phone", { owner: true, method: "POST", body: reply }))).json();
  assert.equal(stored.stored, true); assert.equal(stored.digest, await bodyHash(utf8(canonical(reply))));
  assert.equal(await (await e.operations.handle(await signed("devices/me/room-key"))).text(), canonical(reply));
  assert.equal(await (await e.operations.handle(await signed("devices/key-responses/qa-phone", { owner: true }))).text(), canonical(reply));
  assert.equal((await (await e.operations.handle(await signed("devices/key-requests", { owner: true }))).json()).requests.length, 0);
});

test("sixteen concurrent exact opaque requests create one immutable key request", async () => {
  const e = environment();
  const results = await Promise.all(Array.from({ length: 16 }, async () => (await upload(e)).json()));
  assert.equal(results.filter(value => value.duplicate === false).length, 1);
  assert.equal(results.filter(value => value.duplicate === true).length, 15);
  assert.equal([...e.storage.persisted.keys()].filter(key => key.startsWith("device-key:")).length, 1);
});

test("a changed key request cannot overwrite the first ciphertext or deadline", async () => {
  const e = environment(); await upload(e);
  const original = structuredClone(e.storage.persisted.get(slot));
  for (const changed of [{ ...opaque, requestID: "changed" }, { ...opaque, expiresAt: now + 70_000 },
    { ...opaque, sealed: Buffer.alloc(48, 3).toString("base64url") }]) assert.equal((await upload(e, changed)).status, 409);
  assert.deepEqual(e.storage.persisted.get(slot), original);
});

test("key response duplicates retain exact content and changed replies conflict", async () => {
  const e = environment(); await upload(e); const reply = await responsePacket();
  const post = async body => e.operations.handle(await signed("devices/key-responses/qa-phone", { owner: true, method: "POST", body }));
  assert.equal((await (await post(reply)).json()).duplicate, false);
  assert.equal((await (await post(reply)).json()).duplicate, true);
  assert.equal((await post({ ...reply, sealed: Buffer.alloc(48, 11).toString("base64url") })).status, 409);
  assert.equal((await post({ ...reply, requestDigest: Buffer.alloc(32, 4).toString("base64url") })).status, 409);
});

test("key delivery rejects wrong role, identity and mismatched actual body proof", async () => {
  const e = environment();
  assert.equal((await e.operations.handle(await signed("devices/key-requests"))).status, 403);
  assert.equal((await e.operations.handle(await signed("devices/me/room-key", { owner: true }))).status, 403);
  assert.equal((await upload(e, opaque, { owner: true })).status, 403);
  assert.equal((await upload(e, { ...opaque, deviceID: "somebody-else" })).status, 403);
  assert.equal((await upload(e, opaque, { claims: { [BODY_HASH_CLAIM]: Buffer.alloc(32, 8).toString("base64url") } })).status, 401);
  assert(!e.storage.persisted.has(slot));
});

test("unknown plaintext, duplicate metadata, invalid encoding and oversized body never reach storage", async () => {
  const e = environment();
  for (const value of [{ ...opaque, roomKey: "must-not-be-stored" }, { ...opaque, pairingSecret: "must-not-be-stored" },
    { ...opaque, enc: opaque.enc + "=" }, { ...opaque, version: 2 }]) assert.equal((await upload(e, value)).status, 400);
  assert.equal((await upload(e, opaque, { raw: '{"version":1,' + canonical(opaque).slice(1) })).status, 400);
  assert.equal((await upload(e, opaque, { raw: " ".repeat(8193) })).status, 413);
  assert(!e.storage.persisted.has(slot));
});

test("an unknown device body is rejected before its stream is consumed", async () => {
  const e = environment(), original = await signed("devices/me/key-request", { method: "POST", body: opaque }); let reads = 0;
  const headers = new Headers(original.headers); headers.set("Authorization", "DPoP " + "A".repeat(43));
  const body = new ReadableStream({ pull(controller) { reads++; controller.error(Error("unauthenticated body read")); } }, { highWaterMark: 0 });
  const result = await e.operations.handle(new Request(original, { headers, body, duplex: "half" }));
  assert.equal(result.status, 401); assert.equal(reads, 0);
});

test("revoked recipient or owner cannot obtain pending or stored key deliveries", async () => {
  for (const revoked of [record.deviceID, ownerRecord.deviceID]) {
    const e = environment(); await upload(e);
    e.storage.persisted.set(keys.revoked(revoked), { version: 1, revokedAt: now, by: ownerRecord.deviceID });
    const reply = await responsePacket();
    assert.equal((await e.operations.handle(await signed("devices/key-responses/qa-phone", { owner: true, method: "POST", body: reply }))).status, 401);
    assert.equal((await e.operations.handle(await signed("devices/me/key-request"))).status, 401);
    assert.equal(e.storage.persisted.get(slot).responseBytes, null);
  }
});

test("key delivery expiry is absolute and cannot be renewed by replaying or changing an old body", async () => {
  let time = now; const e = environment({ clock: () => time }); await upload(e);
  time = opaque.expiresAt;
  assert.equal((await upload(e)).status, 410);
  assert.equal((await upload(e, { ...opaque, expiresAt: time + 60_000 })).status, 409);
  assert.equal((await e.operations.handle(await signed("devices/me/room-key"))).status, 204);
  assert.equal(e.storage.persisted.get(slot).expiresAt, opaque.expiresAt);
});

test("a key journal corruption is retained and fails closed instead of silently resetting", async () => {
  const e = environment(); await upload(e);
  const corrupted = { ...e.storage.persisted.get(slot), requestBytes: Buffer.from("corrupt").toString("base64url") };
  e.storage.persisted.set(slot, corrupted);
  assert.equal((await e.operations.handle(await signed("devices/me/key-request"))).status, 503);
  assert.equal((await upload(e)).status, 503);
  assert.deepEqual(e.storage.persisted.get(slot), corrupted);
});

test("request storage failure does not claim success or leave a half-pairing", async () => {
  const e = environment(), original = e.storage.transaction.bind(e.storage);
  e.storage.transaction = callback => original(tx => callback({ ...tx, put: async (key, value) => {
    if (key.startsWith("device-key:")) throw Error("injected key write failure"); return tx.put(key, value);
  } }));
  assert.equal((await upload(e)).status, 503); assert(!e.storage.persisted.has(slot));
});

test("actual Swift HPKE packets and DPoP proofs traverse the actual forwarded v3 entry", async () => {
  const fixture = JSON.parse(await readFile(new URL("fixtures/swift-key-delivery.json", import.meta.url)));
  assert.equal(fixture.synthetic, true); assert.equal(fixture.now, now);
  assert.deepEqual(fixture.roots.map(value => value.deviceID), ["qa-owner", "qa-phone"]);
  assert.equal(fixture.roots[0].keyID, "8795d57b31051f613c241a9052e3ce50");
  const e = environment({ records: fixture.roots });
  const send = wire => forwardDeviceRequest(new Request(wire.url, { method: wire.method, headers: wire.headers, ...(wire.body ? { body: wire.body } : {}) }), e.env);
  assert.equal((await send(fixture.queryRequest)).status, 204);
  assert.equal((await send(fixture.upload)).status, 200);
  assert.equal((await (await send(fixture.uploadAgain)).json()).duplicate, true);
  const list = await (await send(fixture.ownerList)).json();
  assert.equal(list.requests.length, 1);
  assert.equal(Buffer.from(list.requests[0].packet, "base64url").toString(), fixture.upload.body);
  assert.equal((await send(fixture.ownerReply)).status, 200);
  assert.equal((await (await send(fixture.ownerReplyAgain)).json()).duplicate, true);
  assert.equal(await (await send(fixture.queryResponse)).text(), fixture.ownerReply.body);
  assert.equal(await (await send(fixture.ownerQuery)).text(), fixture.ownerReply.body);
});

test("expiry during a key-request commit rolls back rather than accepting stale pairing", async () => {
  let time = now; const e = environment({ clock: () => time }), original = e.storage.transaction.bind(e.storage);
  e.storage.transaction = callback => original(tx => callback({ ...tx, put: async (key, value) => {
    await tx.put(key, value); if (key.startsWith("device-key:")) time = opaque.expiresAt;
  } }));
  assert.equal((await upload(e)).status, 410); assert(!e.storage.persisted.has(slot));
});

test("expiry during a key-response commit rolls back the response without claiming delivered", async () => {
  let time = now; const e = environment({ clock: () => time }); await upload(e);
  const original = e.storage.transaction.bind(e.storage), reply = await responsePacket();
  e.storage.transaction = callback => original(tx => callback({ ...tx, put: async (key, value) => {
    await tx.put(key, value); if (key.startsWith("device-key:") && value.responseBytes) time = opaque.expiresAt;
  } }));
  const result = await e.operations.handle(await signed("devices/key-responses/qa-phone", { owner: true, method: "POST", body: reply }));
  assert.equal(result.status, 410); assert.equal(e.storage.persisted.get(slot).responseBytes, null);
});

test("a principal expiring during key storage cannot get a success receipt", async () => {
  let time = now; const e = environment({ clock: () => time }), original = e.storage.transaction.bind(e.storage);
  e.storage.transaction = callback => original(tx => callback({ ...tx, put: async (key, value) => {
    await tx.put(key, value); if (key.startsWith("device-key:")) time = record.expiresAt;
  } }));
  assert.equal((await upload(e)).status, 401); assert(!e.storage.persisted.has(slot));
});

test("key packets expiring during the final peer checks are not returned as current", async () => {
  for (const [resource, owner] of [["devices/me/key-request", false], ["devices/me/room-key", false],
    ["devices/key-responses/qa-phone", true]]) {
    let time = now; const e = environment({ clock: () => time }); await upload(e);
    assert.equal((await e.operations.handle(await signed("devices/key-responses/qa-phone", {
      owner: true, method: "POST", body: await responsePacket(),
    }))).status, 200);
    const original = e.storage.transaction.bind(e.storage);
    e.storage.transaction = callback => original(tx => {
      let rowRead = false, ownerChecks = 0;
      return callback({ ...tx, get: async key => {
        const value = await tx.get(key);
        if (key === slot) rowRead = true;
        if (rowRead && key === keys.revoked(ownerRecord.deviceID) && ++ownerChecks === (owner ? 4 : 2)) time = opaque.expiresAt;
        return value;
      } });
    });
    const result = await e.operations.handle(await signed(resource, { owner }));
    assert.equal(time, opaque.expiresAt); assert.equal(result.status, 204);
    assert.equal(await result.text(), ""); assert(e.storage.persisted.has(slot));
  }
});

test("owner key lists omit requests that expire while checking their peers", async () => {
  let time = now; const e = environment({ clock: () => time }); await upload(e);
  const original = e.storage.transaction.bind(e.storage);
  e.storage.transaction = callback => original(tx => {
    let listed = false;
    return callback({ ...tx, list: async options => { const rows = await tx.list(options); listed = true; return rows; },
      get: async key => { const value = await tx.get(key);
        if (listed && key === keys.revoked(ownerRecord.deviceID)) time = opaque.expiresAt;
        return value;
      } });
  });
  const result = await e.operations.handle(await signed("devices/key-requests", { owner: true }));
  assert.equal(time, opaque.expiresAt); assert.equal(result.status, 200);
  assert.deepEqual((await result.json()).requests, []); assert(e.storage.persisted.has(slot));
});
