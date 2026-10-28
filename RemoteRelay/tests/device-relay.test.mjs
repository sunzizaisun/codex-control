import { test } from "node:test";
import assert from "node:assert/strict";
import { calculateJwkThumbprint } from "jose";
import { BODY_HASH_CLAIM, bodyHash, tokenHash } from "../src/device-auth.mjs";
import { DeviceRelayOperations } from "../src/device-relay.mjs";
import { deviceRoute, forwardDeviceRequest, legacyDeviceUpgradeRequired } from "../src/device-routing.mjs";
import { readDevicePacket, validDevicePacket } from "../src/device-packets.mjs";
import { context, keys, MemoryJournal, nonce, nonceRecord, now, ownerJWK, ownerRecord, ownerSigner, ownerToken, proof, record, request, token, url } from "./helpers/device-auth-fixture.mjs";

// Opaque synthetic ciphertext-shaped bytes test routing/storage, NOT a real
// conversation, decryption or receipt from dot. Crypto interop is independent.
const packet = (target = "mac", id = "qa-original", overrides = {}) => ({ version: 3, keyID: record.keyID,
  destination: target, id, sentAt: now, expiresAt: now + 60_000, sealed: Buffer.alloc(60, 7).toString("base64"), ...overrides });
class Journal extends MemoryJournal {
  async get(key) { return structuredClone(this.persisted.get(key)); }
  async list({ prefix, startAfter, limit = 1000 }) { return new Map([...this.persisted].filter(([key]) => key.startsWith(prefix) && (!startAfter || key > startAfter)).sort(([a], [b]) => a.localeCompare(b)).slice(0, limit)); }
  async setAlarm(value) { this.nextAlarm = value; }
  async transaction(callback) {
    return super.transaction(tx => callback({ ...tx, list: async ({ prefix, startAfter, limit = 1000 }) =>
      new Map([...(await tx.list({ prefix, limit: 2000 }))].filter(([key]) => !startAfter || key > startAfter).slice(0, limit)) }));
  }
}
function environment({ nonces = true, clock = () => now } = {}) {
  const storage = new Journal(nonces ? new Map([[keys.nonce(), nonceRecord(nonce)], [keys.nonce(ownerRecord.deviceID), nonceRecord(nonce)]]) : new Map());
  const sockets = [], ctx = { storage, getWebSockets: tag => sockets.filter(s => !s.closed && (!tag || s.tags.includes(tag))), setWebSocketAutoResponse() {} };
  const env = { RELAY_DEVICE_ROOTS_V3: JSON.stringify([ownerRecord, record]) };
  return { operations: new DeviceRelayOperations(ctx, env, clock), storage, ctx, env, sockets };
}
async function signed(resource, { method = "GET", body, owner = false, nonceValue = nonce, claims = {}, headers = {} } = {}) {
  const uri = url(resource), encoded = body === undefined ? undefined : JSON.stringify(body);
  const signed = await proof({ uri, method, nonce: nonceValue, ...(owner ? { key: ownerSigner, header: { jwk: ownerJWK } } : {}),
    claims: { ...(owner ? { ath: await tokenHash(ownerToken) } : {}),
      ...(encoded === undefined ? {} : { [BODY_HASH_CLAIM]: await bodyHash(new TextEncoder().encode(encoded)) }), ...claims } });
  return request(signed, { uri, method, accessToken: owner ? ownerToken : token, body: encoded,
    headers: { "X-Codex-Relay-Protocol": "3", "X-Codex-Relay-Key-ID": record.keyID, "X-Codex-Relay-Room": record.roomID, ...headers } });
}
const index = (target, id) => `device-packet:index:${target}:${id}`;
async function post(ops, id = "qa-original", options = {}) {
  return ops.handle(await signed("mailbox/mac", { method: "POST", body: packet("mac", id), ...options }));
}

test("v3 routes are exact, HTTPS-only and scoped to a validated epoch, with bounded mailbox cursors", async () => {
  assert.equal(deviceRoute(await signed("mailbox/mac?cursor=0000000000000001")).cursor, "0000000000000001");
  for (const uri of ["http://relay.example/v3/rooms/qa/snapshot", url("snapshot?extra=1"), url("mailbox/mac?cursor=1"),
    url("mailbox/mac?cursor=0000000000000001&cursor=0000000000000002"), url("devices/me/")]) {
    assert.throws(() => deviceRoute(new Request(uri, { headers: { "X-Codex-Relay-Key-ID": record.keyID } })), { code: "invalid_device_route" });
  }
});

const invitationID = "owner-recovery-original";
const invitationResource = `devices/invitations/${invitationID}`;
const invitationPrefix = `enrollment:invitation:${record.roomID}:${record.keyID}:`;
async function invitationSetup(e = environment()) {
  const body = { invitationID, role: "watch", secretHash: await tokenHash("S".repeat(43)),
    expiresAt: now + 120_000, grantExpiresAt: now + 600_000 };
  const result = await e.operations.handle(await signed("devices/invitations", { owner: true, method: "POST", body }));
  assert.equal(result.status, 200);
  return { ...e, body, created: await result.json() };
}
const invitationRows = storage => [...storage.snapshot()].filter(([key]) => key.startsWith(invitationPrefix));

test("owner invitation recovery queries have an exact known-ID route and forbid query/traversal variants", async () => {
  assert.equal(deviceRoute(await signed(invitationResource, { owner: true })).resource, invitationResource);
  for (const resource of [invitationResource + "/", invitationResource + "?extra=1",
    "devices/invitations/a/b", "devices/invitations/a%2Fb", "devices/invitations/."]) {
    assert.throws(() => deviceRoute(new Request(url(resource), { headers: { "X-Codex-Relay-Key-ID": record.keyID } })),
      { code: "invalid_device_route" });
  }
});

test("owner known-ID query challenges first and missing is 204, never a false successful invitation", async () => {
  const e = environment({ nonces: false });
  const first = await e.operations.handle(await signed(invitationResource, { owner: true }));
  assert.equal(first.status, 401); assert.equal((await first.json()).error, "use_dpop_nonce");
  const result = await e.operations.handle(await signed(invitationResource, { owner: true, nonceValue: first.headers.get("DPoP-Nonce") }));
  assert.equal(result.status, 204); assert.equal(await result.text(), "");
  assert.equal(result.headers.get("X-Codex-Relay-Device-Protocol"), "3");
  assert.equal(result.headers.get("Cache-Control"), "no-store");
  assert.deepEqual(invitationRows(e.storage), []);
});

test("owner query returns the original create digest and public result without changing the business row", async () => {
  const e = await invitationSetup(), before = invitationRows(e.storage);
  for (let round = 0; round < 4; round++) {
    const response = await e.operations.handle(await signed(invitationResource, { owner: true }));
    assert.equal(response.status, 200);
    const result = await response.json();
    assert.deepEqual(Object.keys(result).sort(), ["authorized", "createDigest", "invitation"]);
    assert.equal(result.authorized, true); assert.deepEqual(result.invitation, e.created.invitation);
    assert.equal(result.createDigest, await bodyHash(new TextEncoder().encode(JSON.stringify(e.body))));
    for (const forbidden of [e.body.secretHash, "S".repeat(43), ownerToken, '"tokenHash"', '"jwk"', '"receipt"'])
      assert(!JSON.stringify(result).includes(forbidden));
  }
  assert.deepEqual(invitationRows(e.storage), before);
});

test("only the matching owner may GET a known invitation; methods cannot create, remove or consume it", async () => {
  const e = await invitationSetup(), before = invitationRows(e.storage);
  assert.equal((await e.operations.handle(await signed(invitationResource))).status, 403);
  for (const method of ["POST", "PUT", "DELETE", "HEAD"])
    assert.equal((await e.operations.handle(await signed(invitationResource, { owner: true, method }))).status, 403);
  e.env.RELAY_DEVICE_ROOTS_V3 = JSON.stringify([ownerRecord, { ...record, role: "mac" }]);
  // A second legitimate owner must not learn the first owner's invitation.
  assert.equal((await e.operations.handle(await signed(invitationResource))).status, 204);
  assert.deepEqual(invitationRows(e.storage), before);
});

test("consumed invitation query reports the original consumed state without revealing its receipt", async () => {
  const e = await invitationSetup(), key = invitationPrefix + invitationID;
  e.storage.persisted.get(key).receipt = { bodyDigest: "A".repeat(43), deviceID: record.deviceID };
  const before = invitationRows(e.storage);
  const result = await (await e.operations.handle(await signed(invitationResource, { owner: true }))).json();
  assert.equal(result.invitation.consumed, true); assert.equal(result.receipt, undefined);
  assert.deepEqual(invitationRows(e.storage), before);
});

test("corrupt invitation records are retained with 503 rather than treated as absent or recreated", async () => {
  for (const change of [{ version: 2 }, { invitationID: "other-id" }, { createDigest: "bad" }, { roomID: "other" }]) {
    const e = await invitationSetup(), key = invitationPrefix + invitationID;
    e.storage.persisted.set(key, { ...e.storage.persisted.get(key), ...change });
    const before = invitationRows(e.storage), result = await e.operations.handle(await signed(invitationResource, { owner: true }));
    assert.equal(result.status, 503); assert.equal((await result.json()).error, "device_auth_state_unavailable");
    assert.deepEqual(invitationRows(e.storage), before);
  }
});

test("query rejects an expired original without extending or deleting it", async () => {
  let time = now;
  const e = await invitationSetup(environment({ clock: () => time })), before = invitationRows(e.storage);
  let calls = 0; const transaction = e.storage.transaction.bind(e.storage);
  e.storage.transaction = callback => {
    if (++calls === 2) time = now + 120_000;
    return transaction(callback);
  };
  const result = await e.operations.handle(await signed(invitationResource, { owner: true }));
  assert.equal(result.status, 410); assert.equal((await result.json()).error, "enrollment_invitation_expired");
  assert.deepEqual(invitationRows(e.storage), before);
});

test("owner revocation between proof and invitation-result transactions prevents disclosure", async () => {
  const e = await invitationSetup(), before = invitationRows(e.storage);
  let calls = 0; const transaction = e.storage.transaction.bind(e.storage);
  e.storage.transaction = callback => {
    if (++calls === 2) e.storage.persisted.set(keys.revoked(ownerRecord.deviceID), { version: 1, revokedAt: now, by: "qa-other-owner" });
    return transaction(callback);
  };
  assert.equal((await e.operations.handle(await signed(invitationResource, { owner: true }))).status, 401);
  assert.deepEqual(invitationRows(e.storage), before);
});

test("owner expiry during the final invitation read is checked for both existing and missing IDs", async () => {
  for (const exists of [true, false]) {
    let time = now;
    const e = await invitationSetup(environment({ clock: () => time })); if (!exists) e.storage.persisted.delete(invitationPrefix + invitationID);
    const before = invitationRows(e.storage), transaction = e.storage.transaction.bind(e.storage); let calls = 0;
    e.storage.transaction = callback => transaction(tx => callback(++calls !== 2 ? tx : { ...tx, get: async key => {
      const value = await tx.get(key);
      if (key.startsWith(invitationPrefix)) time = ownerRecord.expiresAt;
      return value;
    } }));
    assert.equal((await e.operations.handle(await signed(invitationResource, { owner: true }))).status, 401);
    assert.deepEqual(invitationRows(e.storage), before);
  }
});

test("sixteen parallel owner queries return one original without creating or consuming invitations", async () => {
  const e = await invitationSetup(), before = invitationRows(e.storage);
  const results = await Promise.all(Array.from({ length: 16 }, async () =>
    (await e.operations.handle(await signed(invitationResource, { owner: true }))).json()));
  assert(results.every(result => result.authorized === true && result.invitation.consumed === false));
  assert.equal(new Set(results.map(result => JSON.stringify(result))).size, 1);
  assert.deepEqual(invitationRows(e.storage), before);
});

test("query checks invitation and owner expiry after the complete result transaction settles", async () => {
  for (const [exists, deadline, status] of [[true, now + 120_000, 410], [true, ownerRecord.expiresAt, 401], [false, ownerRecord.expiresAt, 401]]) {
    let time = now; const e = await invitationSetup(environment({ clock: () => time }));
    if (!exists) e.storage.persisted.delete(invitationPrefix + invitationID);
    const before = invitationRows(e.storage), transact = e.storage.transaction.bind(e.storage); let calls = 0;
    e.storage.transaction = async callback => {
      const value = await transact(callback);
      if (++calls === 2) time = deadline;
      return value;
    };
    assert.equal((await e.operations.handle(await signed(invitationResource, { owner: true }))).status, status);
    assert.deepEqual(invitationRows(e.storage), before);
  }
});

test("an invitation committed before a slow transaction return is not reported live after expiry", async () => {
  for (const [deadline, status] of [[now + 120_000, 410], [ownerRecord.expiresAt, 401]]) {
    let time = now; const e = environment({ clock: () => time }), transact = e.storage.transaction.bind(e.storage); let calls = 0;
    e.storage.transaction = async callback => {
      const value = await transact(callback);
      if (++calls === 2) time = deadline;
      return value;
    };
    const body = { invitationID, role: "watch", secretHash: await tokenHash("S".repeat(43)),
      expiresAt: now + 120_000, grantExpiresAt: now + 600_000 };
    const response = await e.operations.handle(await signed("devices/invitations", { owner: true, method: "POST", body }));
    assert.equal(response.status, status);
    // The commit already succeeded. Preserve the original row; do not claim
    // it rolled back or delete/recreate it to hide an uncertain result.
    assert.equal(invitationRows(e.storage).length, 1);
    assert.equal(e.storage.persisted.get(invitationPrefix + invitationID).expiresAt, body.expiresAt);
  }
});

test("v3 Worker forwarding preserves the real target and ignores asserted protocol/room routing headers", async () => {
  const req = await signed("snapshot", { headers: { "X-Codex-Relay-Protocol": "2", "X-Codex-Relay-Room": "other" } });
  let forwarded;
  const env = { RELAY_DEVICE_ROOTS_V3: JSON.stringify([ownerRecord]), RELAY_ROOMS: {
    idFromName: name => { assert.equal(name, `v3:qa:${record.keyID}`); return name; },
    get: () => ({ fetch: async value => { forwarded = value; return new Response("ok", { headers: { "X-Codex-Relay-Device-Protocol": "3" } }); } }),
  } };
  assert.equal((await forwardDeviceRequest(req, env)).status, 200);
  assert.equal(forwarded.url, req.url); assert.equal(forwarded.headers.get("DPoP"), req.headers.get("DPoP"));
  assert.equal(forwarded.headers.get("X-Codex-Relay-Protocol"), "3"); assert.equal(forwarded.headers.get("X-Codex-Relay-Room"), "qa");
  env.RELAY_ROOMS.get = () => ({ fetch: async () => new Response("old object", { status: 200 }) });
  const old = await forwardDeviceRequest(req, env);
  assert.equal(old.status, 503); assert.equal((await old.json()).error, "cloud_version_updating");
});

test("missing roots and malformed cutover policies fail closed, without legacy fallback", async () => {
  assert.equal((await forwardDeviceRequest(await signed("snapshot"), {})).status, 503);
  assert.equal(legacyDeviceUpgradeRequired(undefined, "qa"), false);
  assert.equal(legacyDeviceUpgradeRequired('["qa"]', "qa"), true);
  assert.equal(legacyDeviceUpgradeRequired('["qa"]', "other"), false);
  assert.throws(() => legacyDeviceUpgradeRequired('["qa"]', undefined), { code: "missing_legacy_room_context" });
  for (const raw of ["broken", "{}", '["qa","qa"]', '["path/room"]']) assert.throws(() => legacyDeviceUpgradeRequired(raw, "qa"), { code: "invalid_device_cutover_policy" });
});

test("v3 packet validation rejects old unsigned transport, noncanonical ciphertext, stale/deferred dates and unknown plaintext", async () => {
  const base = packet(); assert(validDevicePacket(base, { keyID: record.keyID, destination: "mac" }, now));
  for (const changes of [{ version: 2 }, { id: 123 }, { sealed: "AAAA" }, { sealed: base.sealed + "=" },
    { sentAt: now + 60_001 }, { expiresAt: now }, { expiresAt: now + 86_400_001 }, { unexpected: "plaintext" }]) {
    assert.equal(validDevicePacket({ ...base, ...changes }, { keyID: record.keyID, destination: "mac" }, now), false);
  }
  const req = await signed("mailbox/mac", { method: "POST", body: base });
  const parsed = await readDevicePacket(req, { keyID: record.keyID, destination: "mac" }, now);
  assert.deepEqual(parsed.packet, base); assert.equal(parsed.bodyDigest, await bodyHash(new TextEncoder().encode(JSON.stringify(base))));
});

test("HTTP nonce challenge is 401 with DPoP headers and cannot store a packet", async () => {
  const { operations, storage } = environment({ nonces: false });
  const result = await post(operations);
  assert.equal(result.status, 401); assert.equal((await result.json()).error, "use_dpop_nonce");
  assert(result.headers.get("DPoP-Nonce")); assert.equal(result.headers.get("X-Codex-Relay-Device-Protocol"), "3");
  assert(!storage.persisted.has(index("mac", "qa-original")));
});

test("HTTP accepts only the registered role and exact received body, not claimed headers", async () => {
  const { operations, storage } = environment();
  const noDigest = await post(operations, "qa-original", { claims: { [BODY_HASH_CLAIM]: undefined } });
  assert.equal(noDigest.status, 401);
  const put = await operations.handle(await signed("snapshot", { method: "PUT", body: packet("snapshot"), headers: { "X-Role": "mac" } }));
  assert.equal(put.status, 403); assert(!storage.persisted.has("device-packet:snapshot"));
  const cross = await operations.handle(await signed("mailbox/watch", { method: "POST", body: packet("watch") }));
  assert.equal(cross.status, 403);
});

test("an unauthenticated large body is not consumed before key and role preflight", async () => {
  const e = environment(), original = await signed("mailbox/mac", { method: "POST", body: packet() }); let reads = 0;
  const headers = new Headers(original.headers); headers.set("Authorization", "DPoP " + "A".repeat(43));
  const body = new ReadableStream({ pull(controller) { reads++; controller.error(Error("must not read an unauthenticated body")); } }, { highWaterMark: 0 });
  const result = await e.operations.handle(new Request(original, { headers, body, duplex: "half" }));
  assert.equal(result.status, 401); assert.equal(reads, 0);
});

test("a durable queue ACK is not an execution receipt; exact repeats do not duplicate or overwrite", async () => {
  const { operations, storage } = environment();
  const first = await (await post(operations)).json(); assert.equal(first.stored, true); assert.equal(first.delivery, "queued");
  assert.equal(first.executed, undefined); assert.equal(first.replied, undefined);
  const again = await (await post(operations)).json(); assert.equal(again.duplicate, true); assert.equal(again.packetDigest, first.packetDigest);
  const changed = packet("mac", "qa-original", { sealed: Buffer.alloc(60, 8).toString("base64") });
  const conflict = await post(operations, "qa-original", { body: changed }); assert.equal(conflict.status, 409);
  assert.equal([...storage.persisted.keys()].filter(key => key.startsWith("device-packet:queue:mac:")).length, 1);
});

test("sixteen fresh-proof concurrent retries create one original queue row", async () => {
  const { operations } = environment();
  const requests = await Promise.all(Array.from({ length: 16 }, () => signed("mailbox/mac", { method: "POST", body: packet() })));
  const results = await Promise.all(requests.map(async req => (await operations.handle(req)).json()));
  assert.equal(results.filter(value => value.duplicate === false).length, 1);
  assert.equal(results.filter(value => value.duplicate === true).length, 15);
});

test("queue order and opaque pagination retain all originals without skipping or duplicates", async () => {
  const { operations } = environment();
  const ids = ["z-first", "a-second", ...Array.from({ length: 17 }, (_, n) => "packet-" + n)];
  for (const id of ids) assert.equal((await post(operations, id)).status, 200);
  const received = []; let cursor;
  do {
    const page = await (await operations.handle(await signed("mailbox/mac" + (cursor ? "?cursor=" + cursor : ""), { owner: true }))).json();
    assert(page.packets.length <= 8); received.push(...page.packets.map(value => value.id)); cursor = page.nextCursor;
  } while (cursor);
  assert.deepEqual(received, ids); assert.equal(new Set(received).size, ids.length);
});

test("delivery acknowledgement is role-bound, idempotent and retains a durable tombstone", async () => {
  const { operations, storage } = environment(); await post(operations);
  assert.equal((await operations.handle(await signed("mailbox/mac/qa-original", { method: "DELETE" }))).status, 403);
  for (let i = 0; i < 2; i++) assert.equal((await operations.handle(await signed("mailbox/mac/qa-original", { method: "DELETE", owner: true }))).status, 204);
  assert.equal(storage.persisted.get(index("mac", "qa-original")).state, "acknowledged");
  assert.equal((await (await post(operations)).json()).delivery, "acknowledged");
  assert.equal((await (await operations.handle(await signed("mailbox/mac", { owner: true }))).json()).packets.length, 0);
  assert.equal((await operations.handle(await signed("mailbox/mac/unknown", { method: "DELETE", owner: true }))).status, 404);
});

test("a second-write failure rolls the packet/index/sequence back and never returns stored=true", async () => {
  const { operations, storage } = environment(), transact = storage.transaction.bind(storage); let calls = 0;
  storage.transaction = callback => transact(tx => {
    if (++calls !== 2) return callback(tx); let writes = 0;
    return callback({ ...tx, put: async (...args) => { if (++writes === 2) throw Error("injected index write"); return tx.put(...args); } });
  });
  assert.equal((await post(operations)).status, 503);
  assert.equal([...storage.persisted.keys()].some(key => key.startsWith("device-packet:")), false);
  storage.transaction = transact; assert.equal((await post(operations)).status, 200);
});

test("delivery ACK write failure restores the queue and cannot pretend the receiver acknowledged", async () => {
  const e = environment(); await post(e.operations);
  const transact = e.storage.transaction.bind(e.storage); let calls = 0;
  e.storage.transaction = callback => { if (++calls === 2) e.storage.failNext("put"); return transact(callback); };
  const failed = await e.operations.handle(await signed("mailbox/mac/qa-original", { owner: true, method: "DELETE" }));
  assert.equal(failed.status, 503); assert.equal(e.storage.persisted.get(index("mac", "qa-original")).state, "queued");
  e.storage.transaction = transact;
  const page = await (await e.operations.handle(await signed("mailbox/mac", { owner: true }))).json();
  assert.equal(page.packets[0].id, "qa-original");
  assert.equal((await e.operations.handle(await signed("mailbox/mac/qa-original", { owner: true, method: "DELETE" }))).status, 204);
});

test("mailbox response byte budget keeps whole large packets and resumes from the last returned sequence", async () => {
  const e = environment(), sealed = Buffer.alloc(1_400_000, 7).toString("base64");
  for (let i = 0; i < 3; i++) assert.equal((await post(e.operations, "large-" + i, { body: packet("mac", "large-" + i, { sealed }) })).status, 200);
  const first = await (await e.operations.handle(await signed("mailbox/mac", { owner: true }))).json();
  assert.equal(first.packets.length, 2); assert(first.nextCursor);
  const last = await (await e.operations.handle(await signed("mailbox/mac?cursor=" + first.nextCursor, { owner: true }))).json();
  assert.equal(last.packets.length, 1); assert.equal(last.packets[0].id, "large-2"); assert.equal(last.nextCursor, null);
  assert.equal(last.packets[0].sealed, sealed);
});

test("snapshot time cannot move backwards and expired or revoked-owner status is not shown online", async () => {
  let time = now; const { operations, storage } = environment({ clock: () => time });
  assert.equal((await operations.handle(await signed("snapshot", { owner: true, method: "PUT", body: packet("snapshot") }))).status, 200);
  const stale = await (await operations.handle(await signed("snapshot", { owner: true, method: "PUT", body: packet("snapshot", "older", { sentAt: now - 1000 }) }))).json();
  assert.equal(stale.superseded, true);
  assert.equal((await (await operations.handle(await signed("snapshot"))).json()).id, "qa-original");
  storage.persisted.set(keys.revoked(ownerRecord.deviceID), { version: 1, by: "qa-other-owner", revokedAt: now });
  assert.equal((await operations.handle(await signed("snapshot"))).status, 204);
  storage.persisted.delete(keys.revoked(ownerRecord.deviceID)); time = now + 60_000;
  const req = await signed("snapshot"); // Old bounded proof is still in the 5-second grace.
  assert.equal((await operations.handle(req)).status, 204);
});

test("a revoked producer's queued packet is blocked rather than delivered or reported executed", async () => {
  const { operations, storage } = environment(); await post(operations);
  storage.persisted.set(keys.revoked(), { version: 1, by: ownerRecord.deviceID, revokedAt: now });
  const page = await (await operations.handle(await signed("mailbox/mac", { owner: true }))).json();
  assert.equal(page.packets.length, 0); assert.deepEqual(page.rejected, [{ id: "qa-original", reason: "sender_no_longer_authorized" }]);
  assert.equal(storage.persisted.get(index("mac", "qa-original")).state, "blocked");
});

test("peer refresh exposes only public scoped grants and actual persisted revocation metadata", async () => {
  const { operations, storage } = environment();
  storage.persisted.set(keys.revoked(), { version: 1, by: ownerRecord.deviceID, revokedAt: now });
  const data = await (await operations.handle(await signed("devices/peers", { owner: true }))).json();
  assert.equal(data.peers.find(value => value.deviceID === record.deviceID).revokedAt, now);
  assert.equal(JSON.stringify(data).includes("tokenHash"), false); assert.equal(JSON.stringify(data).includes(token), false);
});

test("reconstructed handler uses the same durable ACK and rejects corrupt queue state without repair", async () => {
  const e = environment(); await post(e.operations);
  const replacement = new DeviceRelayOperations(e.ctx, e.env, () => now);
  assert.equal((await (await post(replacement)).json()).duplicate, true);
  const key = [...e.storage.persisted.keys()].find(value => value.startsWith("device-packet:queue:mac:"));
  const corrupt = { version: 9 }; e.storage.persisted.set(key, corrupt);
  assert.equal((await replacement.handle(await signed("mailbox/mac", { owner: true }))).status, 503);
  assert.deepEqual(e.storage.persisted.get(key), corrupt);
});

test("live connection pins, grant expiry and revocation guard socket notifications and pings", async () => {
  const e = environment(), attachment = { version: 3, roomID: record.roomID, keyID: record.keyID,
    deviceID: record.deviceID, role: record.role, thumbprint: await calculateJwkThumbprint(record.jwk), expiresAt: record.expiresAt };
  const socket = { closed: false, sent: [], tags: ["device:" + record.deviceID, "device-mailbox:phone"],
    deserializeAttachment: () => attachment, send(value) { this.sent.push(value); }, close(code) { this.closed = true; this.closeCode = code; } };
  e.sockets.push(socket); await e.operations.socketMessage(socket, "ping"); assert.deepEqual(socket.sent, ["pong"]);
  await e.operations.scheduleSocketExpiry(); assert.equal(e.storage.nextAlarm, record.expiresAt);
  const revoke = await e.operations.handle(await signed(`devices/${record.deviceID}/revoke`, { owner: true, method: "POST" }));
  assert.equal(revoke.status, 200); assert.equal(socket.closed, true); assert.equal(socket.closeCode, 1008);
  assert.equal(await e.operations.connectionAllowed(attachment), false);
});

test("a producer grant expiring during queue storage reads cannot commit a fresh packet", async () => {
  let time = now, calls = 0; const e = environment({ clock: () => time });
  e.env.RELAY_DEVICE_ROOTS_V3 = JSON.stringify([ownerRecord, { ...record, expiresAt: now + 1000 }]);
  const transact = e.storage.transaction.bind(e.storage);
  e.storage.transaction = callback => transact(tx => {
    if (++calls !== 2) return callback(tx);
    return callback({ ...tx, list: async options => { const result = await tx.list(options); time = now + 1000; return result; } });
  });
  assert.equal((await post(e.operations)).status, 401);
  assert.equal([...e.storage.persisted.keys()].some(key => key.startsWith("device-packet:")), false);
});

test("a peer read cannot return after the requesting identity expires during metadata IO", async () => {
  let time = now, calls = 0; const e = environment({ clock: () => time });
  e.env.RELAY_DEVICE_ROOTS_V3 = JSON.stringify([ownerRecord, { ...record, expiresAt: now + 1000 }]);
  const transact = e.storage.transaction.bind(e.storage);
  e.storage.transaction = callback => transact(tx => {
    if (++calls !== 2) return callback(tx); let reads = 0;
    return callback({ ...tx, get: async key => { const result = await tx.get(key); if (++reads === 2) time = now + 1000; return result; } });
  });
  assert.equal((await e.operations.handle(await signed("devices/peers"))).status, 401);
});
