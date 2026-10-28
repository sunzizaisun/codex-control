import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { calculateJwkThumbprint, exportJWK, generateKeyPair } from "jose";
import { authorizeDevice, base64URL, deviceRecords, revokeDevice, roleAllows, targetURI, tokenHash, verifyDeviceProof } from "../src/device-auth.mjs";
import { context, jwk, keys, MemoryJournal, nonce, nonceRecord, now, ownerJWK, ownerRecord, ownerSigner, ownerToken, proof, record, registry, request, token, url } from "./helpers/device-auth-fixture.mjs";

const denied = (code = "invalid_dpop_proof", status = 401) => ({ code, status });
const withNonce = () => new MemoryJournal(new Map([[keys.nonce(), nonceRecord(nonce)]]));
const registered = value => JSON.stringify([value]);

test("a registered grant expiring while proof admission waits for storage cannot authorize", async () => {
  let time = now; const journal = withNonce(), transact = journal.transaction.bind(journal);
  journal.transaction = callback => { time = now + 1000; return transact(callback); };
  await assert.rejects(authorizeDevice(request(await proof({ nonce })), context(), registered({ ...record, expiresAt: now + 1000 }), journal, () => time), denied());
  assert.equal([...journal.persisted.keys()].some(key => key.startsWith("device-auth:replay:")), false);
});

test("a proof that ages out before or during replay-list IO does not reserve authorization", async () => {
  for (const phase of ["before", "list"]) {
    let time = now; const journal = withNonce(), transact = journal.transaction.bind(journal);
    journal.transaction = callback => {
      if (phase === "before") time = now + 66_000;
      return transact(tx => callback({ ...tx, list: async options => { const result = await tx.list(options); time = now + 66_000; return result; } }));
    };
    await assert.rejects(authorizeDevice(request(await proof({ nonce })), context(), registry, journal, () => time), denied());
    assert.equal([...journal.persisted.keys()].some(key => key.startsWith("device-auth:replay:")), false);
  }
});

test("a nonce expiring during the last read rotates to a challenge rather than granting access", async () => {
  let time = now; const journal = new MemoryJournal(new Map([[keys.nonce(), nonceRecord(nonce, now + 4000)]])), transact = journal.transaction.bind(journal);
  journal.transaction = callback => transact(tx => callback({ ...tx, list: async options => { const value = await tx.list(options); time = now + 5000; return value; } }));
  const result = await authorizeDevice(request(await proof({ nonce })), context(), registry, journal, () => time);
  assert.equal(result.authorized, false); assert.notEqual(result.nonce, nonce);
  assert.equal([...journal.persisted.keys()].some(key => key.startsWith("device-auth:replay:")), false);
});

test("revocation rechecks owner expiry at the separate monotonic-tombstone commit", async () => {
  let time = now, calls = 0;
  const journal = new MemoryJournal(new Map([[keys.nonce(ownerRecord.deviceID), nonceRecord(nonce)]])), transact = journal.transaction.bind(journal);
  journal.transaction = callback => { if (++calls === 2) time = now + 1000; return transact(callback); };
  const resource = `devices/${record.deviceID}/revoke`, uri = url(resource);
  const signed = await proof({ uri, nonce, key: ownerSigner, header: { jwk: ownerJWK }, claims: { ath: await tokenHash(ownerToken) } });
  await assert.rejects(revokeDevice(request(signed, { uri, accessToken: ownerToken }), context(resource),
    JSON.stringify([{ ...ownerRecord, expiresAt: now + 1000 }, record]), journal, record.deviceID, () => time), denied());
  assert.equal(journal.persisted.has(keys.revoked()), false);
});

test("registry accepts only distinct enrolled public keys and token hashes", () => {
  assert.deepEqual(deviceRecords(registry), [record]);
  for (const input of ["broken", "{}", "[]", "null", JSON.stringify([record, record]),
    JSON.stringify(Array(65).fill(record)),
    registered({ ...record, jwk: { ...jwk, d: "never-upload" } }),
    registered({ ...record, encryptionKey: "not-authentication" }),
    registered({ ...record, authToken: token }), registered({ ...record, role: "admin" }),
    registered({ ...record, tokenHash: record.tokenHash + "=" }), registered({ ...record, expiresAt: 0 }),
    registered({ ...record, revokedAt: -1 }), registered({ ...record, deviceID: "room/path" }),
    registered({ ...record, keyID: "a".repeat(31) }), registered({ ...record, jwk: { ...jwk, x: "bad" } }),
    JSON.stringify([record, { ...record, deviceID: "other", tokenHash: base64URL(new Uint8Array(32)) }]),
    JSON.stringify([record, { ...record, deviceID: "other", jwk: { ...jwk, x: base64URL(new Uint8Array(32)) } }])]) {
    assert.equal(deviceRecords(input), null, input.slice(0, 80));
  }
});

test("the real Swift CryptoKit fixture verifies through independent jose and WebCrypto", async () => {
  const vector = JSON.parse(await readFile(new URL("./fixtures/swift-device-proof.json", import.meta.url), "utf8"));
  assert.equal(vector.synthetic, true); assert.equal(vector.accessToken, token);
  assert.deepEqual(vector.jwk, jwk);
  assert.equal(await calculateJwkThumbprint(vector.jwk), vector.thumbprint);
  const result = await verifyDeviceProof(request(vector.proof, { uri: vector.url, method: vector.method }), context(), registry, vector.now * 1000);
  assert.equal(result.principal.thumbprint, vector.thumbprint);
  assert.equal(result.nonce, vector.nonce);
  assert.equal(result.jti, "129CDDCB-E568-4F32-B906-93B5631D82C7");
});

test("a current registered signature verifies without turning a proof into authorization", async () => {
  const result = await verifyDeviceProof(request(await proof()), context(), registry, now);
  assert.equal(result.principal.deviceID, record.deviceID);
  assert.equal(result.principal.role, "phone"); assert.equal(result.nonce, undefined);
  assert.equal(result.authorized, undefined);
});

test("unknown token, wrong epoch, expired registration and disabled device never reach storage", async () => {
  const signed = await proof(); const journal = new MemoryJournal();
  for (const [req, route, records] of [
    [request(signed, { accessToken: base64URL(new Uint8Array(32)) }), context(), registry],
    [request(signed), context("mailbox/mac", { keyID: "b".repeat(32) }), registry],
    [request(signed), context(), registered({ ...record, expiresAt: now })],
    [request(signed), context(), registered({ ...record, revokedAt: now })],
  ]) await assert.rejects(authorizeDevice(req, route, records, journal, now), denied());
  assert.equal(journal.transactions, 0);
  await assert.rejects(verifyDeviceProof(request(signed), context(), "[]", now), denied("device_auth_not_configured", 503));
});

test("self-signed unrelated key and private JWK cannot replace the enrolled key", async () => {
  const pair = await generateKeyPair("Ed25519"); const other = await exportJWK(pair.publicKey);
  for (const signed of [await proof({ key: pair.privateKey, header: { jwk: other } }),
    await proof({ header: { jwk: { ...jwk, d: "private" } } }),
    await proof({ header: { jwk: { ...jwk, kid: "untrusted" } } }),
    await proof({ header: { kid: "untrusted" } })]) {
    await assert.rejects(verifyDeviceProof(request(signed), context(), registry, now), denied());
  }
});

test("rejects wrong type, generic algorithm and altered compact signature", async () => {
  const signed = await proof(); const segments = signed.split(".");
  const alteredSignature = (segments[2][0] === "A" ? "B" : "A") + segments[2].slice(1);
  for (const candidate of [await proof({ header: { typ: "JWT" } }), await proof({ header: { alg: "EdDSA" } }),
    `${segments[0]}.${segments[1]}.${alteredSignature}`]) {
    await assert.rejects(verifyDeviceProof(request(candidate), context(), registry, now), denied());
  }
});

test("proof binds token hash, actual method and target, not client routing assertions", async () => {
  for (const claims of [{ ath: base64URL(new Uint8Array(32)) }, { htm: "GET" }, { htu: "https://other.example/v3/rooms/qa/mailbox/mac" },
    { htu: url() + "?unsigned=1" }, { htu: "http://relay.example/v3/rooms/qa/mailbox/mac" }]) {
    await assert.rejects(verifyDeviceProof(request(await proof({ claims })), context(), registry, now), denied());
  }
  await assert.rejects(verifyDeviceProof(request(await proof()), context("snapshot"), registry, now), denied());
  await assert.rejects(verifyDeviceProof(request(await proof()), context("mailbox/mac", { roomID: "other" }), registry, now), denied());
});

test("the complete route path must match, not merely a suffix after an unrelated prefix", async () => {
  const uri = "https://relay.example/unrelated-prefix/v3/rooms/qa/mailbox/mac";
  await assert.rejects(verifyDeviceProof(request(await proof({ uri }), { uri }), context(), registry, now), denied());
});

test("query and fragment are excluded by RFC 9449 but request body is NOT signed by DPoP", async () => {
  assert.equal(targetURI("https://RELAY.example:443?ignored=1#fragment"), "https://relay.example/");
  const signed = await proof({ uri: url() + "?one=1#fragment" });
  const result = await verifyDeviceProof(request(signed, { uri: url() + "?two=2", body: "different encrypted packet" }), context(), registry, now);
  assert.equal(result.principal.deviceID, record.deviceID);
  // This passing test records a protocol limitation, NOT body authenticity.
  // A separately signed immutable envelope remains a migration release gate.
  for (const raw of ["http://relay.example/", "https://user:pass@relay.example/", "broken"]) assert.throws(() => targetURI(raw), denied());
});

test("all required claims are mandatory and only a bounded current proof is accepted", async () => {
  for (const name of ["iat", "jti", "htm", "htu", "ath"]) {
    await assert.rejects(verifyDeviceProof(request(await proof({ claims: { [name]: undefined } })), context(), registry, now), denied());
  }
  for (const claims of [{ iat: now / 1000 - 66 }, { iat: now / 1000 + 6 }, { iat: now / 1000 + 0.5 },
    { jti: "short" }, { jti: "x".repeat(161) }, { jti: "有效编号01234567890123456789" }, { nonce: "bad nonce" }, { nonce: "" }]) {
    await assert.rejects(verifyDeviceProof(request(await proof({ claims })), context(), registry, now), denied());
  }
});

test("bearer fallback, joined duplicate headers, padded token and oversized proof are rejected", async () => {
  const signed = await proof();
  for (const headers of [{ Authorization: `Bearer ${token}` }, { Authorization: `DPoP ${token}, DPoP ${token}` },
    { Authorization: `DPoP ${token}=` }, { DPoP: signed + "," + signed }, { DPoP: "a".repeat(4097) }, { DPoP: "" }]) {
    await assert.rejects(verifyDeviceProof(request(signed, { headers }), context(), registry, now), denied());
  }
});

test("role matrix scopes snapshots, streams and mailbox directions", () => {
  const roles = ["mac", "phone", "watch"];
  for (const role of roles) {
    assert.equal(roleAllows(role, "GET", "snapshot"), true);
    assert.equal(roleAllows(role, "PUT", "snapshot"), role === "mac");
    for (const destination of roles) {
      assert.equal(roleAllows(role, "GET", `stream/${destination}`), role === destination);
      assert.equal(roleAllows(role, "GET", `mailbox/${destination}`), role === destination);
      assert.equal(roleAllows(role, "DELETE", `mailbox/${destination}/valid-id`), role === destination);
      assert.equal(roleAllows(role, "POST", `mailbox/${destination}`), role === "mac" ? destination !== "mac" : destination === "mac");
    }
    assert.equal(roleAllows(role, "POST", "devices/qa-watch/revoke"), role === "mac");
    for (const resource of ["mailbox/phone/../mac", "stream/mac/extra", "snapshot?role=mac", "snapshot#anything", "devices/../revoke", "mailbox/nope"]) {
      assert.equal(roleAllows(role, "POST", resource), false);
    }
  }
  assert.equal(roleAllows("admin", "GET", "snapshot"), false);
});

test("valid proof cannot elevate a mobile role by routing or an unsigned header", async () => {
  const journal = new MemoryJournal();
  for (const [resource, method] of [["snapshot", "PUT"], ["mailbox/watch", "POST"], ["mailbox/mac", "GET"], ["stream/mac", "GET"], ["devices/qa-watch/revoke", "POST"]]) {
    const uri = url(resource);
    await assert.rejects(authorizeDevice(request(await proof({ uri, method }), { uri, method, headers: { "X-Device-Role": "mac" } }), context(resource), registry, journal, now), denied("device_role_forbidden", 403));
  }
  assert.equal(journal.transactions, 0);
});

test("first signed request only challenges and cannot consume a replay identifier", async () => {
  const journal = new MemoryJournal(); const signed = await proof();
  const first = await authorizeDevice(request(signed), context(), registry, journal, now);
  assert.equal(first.authorized, false); assert.match(first.nonce, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(journal.persisted.size, 1);
  assert.equal(journal.persisted.get(keys.nonce()).nonce, first.nonce);
  const again = await authorizeDevice(request(signed), context(), registry, journal, now + 1000);
  assert.deepEqual(again, first);
  const fresh = await authorizeDevice(request(await proof({ nonce: first.nonce })), context(), registry, journal, now + 1000);
  assert.equal(fresh.authorized, true);
});

test("fresh journals issue independently randomized challenge values", async () => {
  const outputs = new Set();
  for (let index = 0; index < 8; index++) outputs.add((await authorizeDevice(request(await proof()), context(), registry, new MemoryJournal(), now)).nonce);
  assert.equal(outputs.size, 8);
});

test("wrong nonce does not rotate a live challenge or reserve proof replay state", async () => {
  const journal = withNonce();
  const result = await authorizeDevice(request(await proof({ nonce: "untrusted" })), context(), registry, journal, now);
  assert.deepEqual(result, { authorized: false, nonce }); assert.equal(journal.persisted.size, 1);
});

test("expired nonce rotates once and an old value cannot revive it", async () => {
  const journal = new MemoryJournal(new Map([[keys.nonce(), nonceRecord(nonce, now)]]));
  const first = await authorizeDevice(request(await proof({ nonce })), context(), registry, journal, now);
  assert.equal(first.authorized, false); assert.notEqual(first.nonce, nonce);
  const again = await authorizeDevice(request(await proof({ nonce })), context(), registry, journal, now);
  assert.equal(again.nonce, first.nonce);
  assert.equal((await authorizeDevice(request(await proof({ nonce: first.nonce })), context(), registry, journal, now)).authorized, true);
});

test("same proof is rejected sequentially and after journal reconstruction", async () => {
  const journal = withNonce(); const signed = await proof({ nonce });
  assert.equal((await authorizeDevice(request(signed), context(), registry, journal, now)).authorized, true);
  await assert.rejects(authorizeDevice(request(signed), context(), registry, journal, now), denied("dpop_proof_replayed"));
  const reconstructed = new MemoryJournal(journal.persisted);
  await assert.rejects(authorizeDevice(request(signed), context(), registry, reconstructed, now + 1000), denied("dpop_proof_replayed"));
});

test("sixteen concurrent identical proofs commit one authorization in the transactional fake", async () => {
  const journal = withNonce(); const signed = await proof({ nonce });
  const results = await Promise.allSettled(Array.from({ length: 16 }, () => authorizeDevice(request(signed), context(), registry, journal, now)));
  assert.equal(results.filter(value => value.status === "fulfilled" && value.value.authorized).length, 1);
  const rejected = results.filter(value => value.status === "rejected"); assert.equal(rejected.length, 15);
  for (const result of rejected) assert.equal(result.reason.code, "dpop_proof_replayed");
});

test("new proof identifier can retry the same body, without proving owner execution or idempotence", async () => {
  const journal = withNonce(); const body = "the same immutable encrypted packet";
  for (let index = 0; index < 3; index++) assert.equal((await authorizeDevice(request(await proof({ nonce }), { body }), context(), registry, journal, now)).authorized, true);
  assert.equal([...journal.persisted.keys()].filter(key => key.startsWith("device-auth:replay:")).length, 3);
});

test("a failed storage read, nonce write, replay list or replay commit never grants access", async () => {
  for (const operation of ["get", "put", "list", "commit"]) {
    const journal = withNonce(); const before = journal.snapshot(); journal.failNext(operation);
    await assert.rejects(authorizeDevice(request(await proof({ nonce })), context(), registry, journal, now), denied("device_auth_state_unavailable", 503));
    assert.deepEqual(journal.persisted, before);
  }
  const journal = new MemoryJournal(); journal.failNext("put");
  await assert.rejects(authorizeDevice(request(await proof()), context(), registry, journal, now), denied("device_auth_state_unavailable", 503));
  assert.equal(journal.persisted.size, 0);
});

test("corrupt nonce, revocation or replay state fails closed rather than being overwritten", async () => {
  for (const [key, value] of [[keys.nonce(), { version: 1, nonce: "bad", expiresAt: now + 1 }],
    [keys.revoked(), { version: 2, revokedAt: now, by: "owner" }],
    [keys.replay("corrupt"), { version: 1, expiresAt: "forever" }]]) {
    const journal = withNonce(); journal.persisted.set(key, value); const before = journal.snapshot();
    await assert.rejects(authorizeDevice(request(await proof({ nonce })), context(), registry, journal, now), denied("device_auth_state_unavailable", 503));
    assert.deepEqual(journal.persisted, before);
  }
});

test("expired replay rows are collected transactionally; delete failure is not authorization", async () => {
  for (const shouldFail of [false, true]) {
    const journal = withNonce(); journal.persisted.set(keys.replay("expired"), { version: 1, expiresAt: now });
    if (shouldFail) journal.failNext("delete");
    const pending = authorizeDevice(request(await proof({ nonce })), context(), registry, journal, now);
    if (shouldFail) {
      await assert.rejects(pending, denied("device_auth_state_unavailable", 503));
      assert.equal(journal.persisted.has(keys.replay("expired")), true);
    } else { assert.equal((await pending).authorized, true); assert.equal(journal.persisted.has(keys.replay("expired")), false); }
  }
});

test("live replay capacity is bounded and overflow or corrupt excess cannot silently evict proofs", async () => {
  for (const count of [1024, 1025]) {
    const journal = withNonce();
    for (let index = 0; index < count; index++) journal.persisted.set(keys.replay(String(index).padStart(4, "0")), { version: 1, expiresAt: now + 1000 });
    const before = journal.snapshot();
    await assert.rejects(authorizeDevice(request(await proof({ nonce })), context(), registry, journal, now), count === 1024
      ? denied("device_auth_busy", 429) : denied("device_auth_state_unavailable", 503));
    assert.deepEqual(journal.persisted, before);
  }
});

test("room and epoch scope isolate nonce, revocation and consumed proof state", async () => {
  const journal = withNonce();
  journal.persisted.set(keys.revoked(record.deviceID, "different-room"), { version: 1, revokedAt: now, by: "owner" });
  journal.persisted.set(keys.revoked(record.deviceID, record.roomID, "b".repeat(32)), { version: 1, revokedAt: now, by: "owner" });
  assert.equal((await authorizeDevice(request(await proof({ nonce })), context(), registry, journal, now)).authorized, true);
});

const ownerRegistry = JSON.stringify([ownerRecord, { ...record, deviceID: "qa-target" }]);
const ownerJournal = () => new MemoryJournal(new Map([[keys.nonce("qa-owner"), nonceRecord(nonce)]]));
async function revocationRequest(deviceID = "qa-target") {
  const resource = `devices/${deviceID}/revoke`, uri = url(resource);
  return [request(await proof({ uri, nonce, key: ownerSigner, header: { jwk: ownerJWK }, claims: { ath: await tokenHash(ownerToken) } }), { uri, accessToken: ownerToken }), context(resource)];
}

test("revocation requires a fresh signed registered owner, not a JSON role assertion", async () => {
  const [req, route] = await revocationRequest();
  const phoneRequest = request(await proof({ uri: req.url, nonce }), { uri: req.url });
  await assert.rejects(revokeDevice(phoneRequest, route, registry, withNonce(), "qa-target", now), denied("device_role_forbidden", 403));
  await assert.rejects(revokeDevice(new Request(req.url, { method: "POST", headers: { "X-Device-Role": "mac" } }), route, ownerRegistry, ownerJournal(), "qa-target", now), denied());
});

test("successful owner revocation is durable, monotonic and blocks the target's next proof", async () => {
  const journal = ownerJournal(); const [req, route] = await revocationRequest();
  const result = await revokeDevice(req, route, ownerRegistry, journal, "qa-target", now);
  assert.equal(result.authorized, true); assert.equal(result.revoked, true);
  const tombstone = journal.persisted.get(keys.revoked("qa-target"));
  assert.deepEqual(tombstone, { version: 1, revokedAt: now, by: "qa-owner" });
  const [again] = await revocationRequest();
  await revokeDevice(again, route, ownerRegistry, new MemoryJournal(journal.persisted), "qa-target", now + 1000);
  assert.deepEqual(journal.persisted.get(keys.revoked("qa-target")), tombstone);
  // A target with a matching registered key/token still loses to its persisted tombstone.
  journal.persisted.set(keys.nonce("qa-target"), nonceRecord(nonce));
  await assert.rejects(authorizeDevice(request(await proof({ nonce })), context(), ownerRegistry, new MemoryJournal(journal.persisted), now), denied());
});

test("revocation cannot claim success for unknown target, current owner or an unproved challenge", async () => {
  for (const [device, error] of [["unknown", denied("device_not_found", 404)], ["qa-owner", denied("cannot_revoke_current_owner", 409)]]) {
    const [req, route] = await revocationRequest(device); const journal = ownerJournal();
    await assert.rejects(revokeDevice(req, route, ownerRegistry, journal, device, now), error);
    assert.equal([...journal.persisted.keys()].some(key => key.startsWith("device-auth:revoked:")), false);
  }
  const [req, route] = await revocationRequest(); const journal = new MemoryJournal();
  const result = await revokeDevice(req, route, ownerRegistry, journal, "qa-target", now);
  assert.equal(result.authorized, false); assert.equal(result.revoked, undefined);
});

test("revocation write failure is not a false acknowledgement and corrupt tombstones are not repaired", async () => {
  const journal = ownerJournal();
  const original = journal.transaction.bind(journal); let calls = 0;
  journal.transaction = callback => { if (++calls === 2) journal.failNext("put"); return original(callback); };
  const [req, route] = await revocationRequest();
  await assert.rejects(revokeDevice(req, route, ownerRegistry, journal, "qa-target", now), denied("device_auth_state_unavailable", 503));
  assert.equal(journal.persisted.has(keys.revoked("qa-target")), false);
  journal.persisted.set(keys.revoked("qa-target"), { version: 9 });
  const [again] = await revocationRequest();
  await assert.rejects(revokeDevice(again, route, ownerRegistry, journal, "qa-target", now), denied("device_auth_state_unavailable", 503));
  assert.deepEqual(journal.persisted.get(keys.revoked("qa-target")), { version: 9 });
});

test("revoked owner cannot use a previously prepared request to revoke another device", async () => {
  const journal = ownerJournal(); const [req, route] = await revocationRequest();
  journal.persisted.set(keys.revoked("qa-owner"), { version: 1, revokedAt: now, by: "another-owner" });
  await assert.rejects(revokeDevice(req, route, ownerRegistry, journal, "qa-target", now), denied());
  assert.equal(journal.persisted.has(keys.revoked("qa-target")), false);
});

test("an owner revoked between proof admission and revocation commit is rechecked", async () => {
  const journal = ownerJournal(); const transaction = journal.transaction.bind(journal); let calls = 0;
  journal.transaction = async callback => {
    const result = await transaction(callback);
    if (++calls === 1) journal.persisted.set(keys.revoked("qa-owner"), { version: 1, revokedAt: now, by: "another-owner" });
    return result;
  };
  const [req, route] = await revocationRequest();
  await assert.rejects(revokeDevice(req, route, ownerRegistry, journal, "qa-target", now), denied());
  assert.equal(journal.persisted.has(keys.revoked("qa-target")), false);
});

test("two enrolled devices receive distinct challenges in the same journal", async () => {
  const journal = new MemoryJournal(), uri = url("snapshot");
  const records = JSON.stringify([record, ownerRecord]);
  const phone = request(await proof({ uri, method: "GET" }), { uri, method: "GET" });
  const owner = request(await proof({ uri, method: "GET", key: ownerSigner, header: { jwk: ownerJWK }, claims: { ath: await tokenHash(ownerToken) } }),
    { uri, method: "GET", accessToken: ownerToken });
  const a = await authorizeDevice(phone, context("snapshot"), records, journal, now);
  const b = await authorizeDevice(owner, context("snapshot"), records, journal, now);
  assert.equal(a.authorized, false); assert.equal(b.authorized, false); assert.notEqual(a.nonce, b.nonce);
  assert.equal(journal.persisted.get(keys.nonce(record.deviceID)).nonce, a.nonce);
  assert.equal(journal.persisted.get(keys.nonce(ownerRecord.deviceID)).nonce, b.nonce);
});

test("same replay identifier on independently enrolled devices is scoped to the signing device", async () => {
  const journal = withNonce(), uri = url("snapshot"), jti = "shared-public-qa-identifier";
  journal.persisted.set(keys.nonce(ownerRecord.deviceID), nonceRecord(nonce));
  const records = JSON.stringify([record, ownerRecord]);
  const phoneProof = await proof({ uri, method: "GET", nonce, claims: { jti } });
  const ownerProof = await proof({ uri, method: "GET", nonce, key: ownerSigner, header: { jwk: ownerJWK }, claims: { jti, ath: await tokenHash(ownerToken) } });
  assert.equal((await authorizeDevice(request(phoneProof, { uri, method: "GET" }), context("snapshot"), records, journal, now)).authorized, true);
  assert.equal((await authorizeDevice(request(ownerProof, { uri, method: "GET", accessToken: ownerToken }), context("snapshot"), records, journal, now)).authorized, true);
  await assert.rejects(authorizeDevice(request(ownerProof, { uri, method: "GET", accessToken: ownerToken }), context("snapshot"), records, journal, now), denied("dpop_proof_replayed"));
});

test("a signed role assertion and forwarding headers cannot grant extra privileges", async () => {
  const uri = url("mailbox/watch");
  const req = request(await proof({ uri, nonce, claims: { role: "mac", deviceID: "qa-owner" } }), {
    uri, headers: { "X-Forwarded-Proto": "https", "X-Device-Role": "mac", "X-Device-ID": "qa-owner" },
  });
  await assert.rejects(authorizeDevice(req, context("mailbox/watch"), registry, withNonce(), now), denied("device_role_forbidden", 403));
});

test("expired proof cannot be revived merely by a still-current nonce", async () => {
  const journal = withNonce(); const signed = await proof({ nonce, time: now - 66_000 });
  await assert.rejects(authorizeDevice(request(signed), context(), registry, journal, now), denied());
  assert.equal(journal.transactions, 0);
});

test("a failed replay commit leaves no false reservation and permits an exact bounded retry", async () => {
  const journal = withNonce(), signed = await proof({ nonce }); journal.failNext("commit");
  await assert.rejects(authorizeDevice(request(signed), context(), registry, journal, now), denied("device_auth_state_unavailable", 503));
  assert.equal(journal.persisted.size, 1);
  assert.equal((await authorizeDevice(request(signed), context(), registry, journal, now)).authorized, true);
  await assert.rejects(authorizeDevice(request(signed), context(), registry, journal, now), denied("dpop_proof_replayed"));
});
