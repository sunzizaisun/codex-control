import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { generateKeyPair, exportJWK } from "jose";
import { BODY_HASH_CLAIM, base64URL, bodyHash, revokeDevice, tokenHash, verifyDeviceProof } from "../src/device-auth.mjs";
import { createEnrollmentInvitation, enrolledDeviceRecords, readOwnEnrollment, redeemEnrollmentInvitation } from "../src/device-enrollment.mjs";
import { deviceRoute } from "../src/device-routing.mjs";
import { context, jwk, keys, MemoryJournal, nonce, nonceRecord, now, ownerJWK, ownerRecord, ownerSigner, ownerToken, proof, record, request, token, url } from "./helpers/device-auth-fixture.mjs";

// Unit-only transactional fake. Real SQLite/runtime coverage is separate.
class Journal extends MemoryJournal {
  async get(key) { if (this.failRead) throw Error("injected read failure"); return structuredClone(this.persisted.get(key)); }
}
const roots = JSON.stringify([ownerRecord]);
const invitationToken = base64URL(new Uint8Array(32).fill(95));
const registryKey = `enrollment:registry:${record.roomID}:${record.keyID}:`;
const invitePrefix = `enrollment:invitation:${record.roomID}:${record.keyID}:`;
const invitationID = "synthetic-invitation";
const denied = (code = "invalid_dpop_proof", status = 401) => ({ code, status });
const journal = () => new Journal(new Map([[keys.nonce(ownerRecord.deviceID), nonceRecord(nonce)]]));

test("the actual native enrollment request verifies independently with exact body, token and nonce binding", async () => {
  const vector = JSON.parse(await readFile(new URL("./fixtures/swift-enrollment.json", import.meta.url), "utf8"));
  assert.equal(vector.synthetic, true); assert.equal(vector.record.deviceID, "qa-phone");
  assert.equal(vector.record.jwk.x, jwk.x);
  assert.equal(vector.keyIDHeader, vector.record.keyID);
  const req = () => new Request(vector.uri, { method: vector.method, body: vector.body,
    headers: { Authorization: vector.authorization, DPoP: vector.proof, "X-Codex-Relay-Key-ID": vector.keyIDHeader } });
  const route = { ...deviceRoute(req()), bodyDigest: await bodyHash(new TextEncoder().encode(vector.body)) };
  const result = await verifyDeviceProof(req(), route, JSON.stringify([vector.record]), vector.now);
  assert.equal(result.principal.deviceID, vector.record.deviceID); assert.equal(result.nonce, vector.nonce);
  await assert.rejects(verifyDeviceProof(req(), { ...route, bodyDigest: await bodyHash(new TextEncoder().encode(vector.body + " ")) },
    JSON.stringify([vector.record]), vector.now), denied());
});
async function createBody(overrides = {}) {
  return { invitationID, role: "phone", secretHash: await tokenHash(invitationToken), expiresAt: now + 120_000,
    grantExpiresAt: now + 600_000, ...overrides };
}
async function ownerRequest(body, { time = now, digest = true, bodyBytes = JSON.stringify(body), ...options } = {}) {
  const uri = url("devices/invitations");
  const signed = await proof({ uri, nonce, time, key: ownerSigner, header: { jwk: ownerJWK },
    claims: { ath: await tokenHash(ownerToken), ...(digest ? { [BODY_HASH_CLAIM]: await bodyHash(new TextEncoder().encode(bodyBytes)) } : {}), ...options.claims } });
  return request(signed, { uri, accessToken: ownerToken, body: bodyBytes, ...options.request });
}
async function create(storage, options = {}, time = now) {
  const body = await createBody(options);
  return createEnrollmentInvitation(await ownerRequest(body, { time }), context("devices/invitations"), roots, storage, time);
}
async function redemption(invitation, { body: changes = {}, bodyBytes, time = now, proofChanges = {}, ...options } = {}) {
  const body = { invitationID, deviceID: record.deviceID, jwk, tokenHash: await tokenHash(token), ...changes };
  bodyBytes ??= JSON.stringify(body);
  const uri = url("devices/enroll");
  const signed = await proof({ uri, nonce: invitation.nonce, time,
    claims: { ath: await tokenHash(invitationToken), [BODY_HASH_CLAIM]: await bodyHash(new TextEncoder().encode(bodyBytes)), ...proofChanges } });
  return request(signed, { uri, accessToken: invitationToken, body: bodyBytes, ...options });
}
async function enroll(storage, options) {
  const { invitation } = await create(storage);
  return redeemEnrollmentInvitation(await redemption(invitation, options), context("devices/enroll"), roots, storage, now);
}
async function selfRequest(nonceValue, time = now) {
  const uri = url("devices/me");
  return request(await proof({ method: "GET", uri, time, nonce: nonceValue }), { method: "GET", uri });
}

test("owner invitation and enrolled device contain no plaintext token, invitation secret or private JWK", async () => {
  const storage = journal();
  const { invitation } = await create(storage);
  assert.equal(invitation.expiresAt, now + 120_000); assert.equal(invitation.consumed, false);
  const result = await redeemEnrollmentInvitation(await redemption(invitation), context("devices/enroll"), roots, storage, now);
  assert.equal(result.enrolled, true); assert.equal(result.alreadyEnrolled, false);
  assert.equal(result.grant.deviceID, record.deviceID); assert.equal(result.grant.role, "phone");
  assert.equal(result.grant.tokenHash, undefined);
  assert.equal((await enrolledDeviceRecords(storage, roots, context())).length, 2);
  const serialized = JSON.stringify([...storage.persisted]);
  assert(!serialized.includes(token)); assert(!serialized.includes(ownerToken)); assert(!serialized.includes(invitationToken));
  assert(!serialized.includes('"d":')); assert(!serialized.includes('"privateKey"'));
});

test("unproved owner receives only a nonce challenge and cannot mint an invitation", async () => {
  const storage = new Journal();
  const result = await create(storage);
  assert.equal(result.authorized, false); assert.equal(result.invitation, undefined);
  assert.equal([...storage.persisted.keys()].some(value => value.startsWith(invitePrefix)), false);
});

test("missing or altered body digest cannot create an owner invitation", async () => {
  for (const options of [{ digest: false }, { claims: { [BODY_HASH_CLAIM]: base64URL(new Uint8Array(32)) } }]) {
    const storage = journal(), body = await createBody();
    await assert.rejects(createEnrollmentInvitation(await ownerRequest(body, options), context("devices/invitations"), roots, storage, now), denied());
    assert.equal(storage.transactions, 0);
  }
});

test("a mobile role cannot create an invitation even with a valid registered key and body binding", async () => {
  const body = await createBody(), bytes = JSON.stringify(body), uri = url("devices/invitations");
  const signed = await proof({ uri, nonce, claims: { [BODY_HASH_CLAIM]: await bodyHash(new TextEncoder().encode(bytes)) } });
  await assert.rejects(createEnrollmentInvitation(request(signed, { uri, body: bytes }), context("devices/invitations"),
    JSON.stringify([ownerRecord, record]), journal(), now), denied("device_role_forbidden", 403));
});

test("exact owner retry keeps the original nonce/deadline; changed content conflicts", async () => {
  const storage = journal(), first = await create(storage), repeated = await create(storage);
  assert.deepEqual(first.invitation, repeated.invitation);
  await assert.rejects(create(storage, { role: "watch" }), denied("enrollment_invitation_conflict", 409));
  assert.equal([...storage.persisted.keys()].filter(key => key.startsWith(invitePrefix)).length, 1);
});

test("expired invitations are collected but delayed original bodies never extend their deadline", async () => {
  const storage = journal(); await create(storage);
  const later = now + 121_000;
  storage.persisted.set(keys.nonce(ownerRecord.deviceID), nonceRecord(nonce, later + 120_000));
  await create(storage, { invitationID: "next", expiresAt: later + 90_000 }, later);
  assert.equal(storage.persisted.has(invitePrefix + invitationID), false);
  await assert.rejects(create(storage, {}, later), denied("enrollment_invitation_expired", 410));
});

test("owner grant lifetime, role, absolute invitation lifetime, secret and exact schema are enforced", async () => {
  for (const changes of [{ grantExpiresAt: ownerRecord.expiresAt + 1 }, { role: "mac" }, { expiresAt: now + 120_001 },
    { expiresAt: now + 90_000, grantExpiresAt: now + 80_000 }, { secretHash: ownerRecord.tokenHash },
    { secretHash: "not-a-hash" }, { unexpected: true }]) {
    await assert.rejects(create(journal(), changes), denied("invalid_enrollment_body", 400));
  }
  await assert.rejects(create(journal(), { expiresAt: now }), denied("enrollment_invitation_expired", 410));
});

test("a redemption needs both invitation secret and prospective private key plus its exact body", async () => {
  const storage = journal(), { invitation } = await create(storage);
  const pair = await generateKeyPair("Ed25519"), otherJWK = await exportJWK(pair.publicKey);
  for (const changes of [{ accessToken: ownerToken }, { body: { jwk: otherJWK } },
    { proofChanges: { [BODY_HASH_CLAIM]: undefined } }, { proofChanges: { [BODY_HASH_CLAIM]: base64URL(new Uint8Array(32)) } },
    { proofChanges: { nonce: "wrong-nonce" } }]) {
    await assert.rejects(redeemEnrollmentInvitation(await redemption(invitation, changes), context("devices/enroll"), roots, storage, now), denied(changes.proofChanges?.nonce ? "invalid_enrollment_invitation" : "invalid_dpop_proof"));
  }
  assert.equal(storage.persisted.has(registryKey), false);
});

test("private, extra, malformed JWKs and reused access capabilities are input errors, never server registration", async () => {
  const storage = journal(), { invitation } = await create(storage);
  for (const body of [{ jwk: { ...jwk, d: "private" } }, { jwk: { ...jwk, kid: "extra" } },
    { jwk: { ...jwk, x: "bad" } }, { tokenHash: await tokenHash(invitationToken) }, { tokenHash: ownerRecord.tokenHash },
    { extra: true }, { role: "mac" }]) {
    await assert.rejects(redeemEnrollmentInvitation(await redemption(invitation, { body }), context("devices/enroll"), roots, storage, now), denied("invalid_enrollment_body", 400));
  }
  assert.equal(storage.persisted.has(registryKey), false);
});

test("sixteen concurrent identical redemptions commit one grant and acknowledge that same result", async () => {
  const storage = journal(), { invitation } = await create(storage);
  const results = await Promise.all(Array.from({ length: 16 }, async () =>
    redeemEnrollmentInvitation(await redemption(invitation), context("devices/enroll"), roots, storage, now)));
  assert.equal(results.filter(value => value.alreadyEnrolled === false).length, 1);
  assert.equal(results.filter(value => value.alreadyEnrolled === true).length, 15);
  assert.equal(storage.persisted.get(registryKey).grants.length, 1);
  assert(results.every(value => JSON.stringify(value.grant) === JSON.stringify(results[0].grant)));
});

test("a consumed invitation cannot enroll a different identity or replace its access token", async () => {
  const storage = journal(), { invitation } = await create(storage);
  await redeemEnrollmentInvitation(await redemption(invitation), context("devices/enroll"), roots, storage, now);
  for (const body of [{ deviceID: "other-phone" }, { tokenHash: base64URL(new Uint8Array(32).fill(8)) }]) {
    await assert.rejects(redeemEnrollmentInvitation(await redemption(invitation, { body }), context("devices/enroll"), roots, storage, now), denied("enrollment_invitation_used", 409));
  }
});

test("lost enrollment ACK is recovered with the same locally saved identity after invitation expiry and journal recreation", async () => {
  const storage = journal(); await enroll(storage);
  const restored = new Journal(storage.persisted), later = now + 121_000;
  const challenge = await readOwnEnrollment(await selfRequest(undefined, later), context("devices/me"), roots, restored, later);
  assert.equal(challenge.authorized, false);
  const result = await readOwnEnrollment(await selfRequest(challenge.nonce, later), context("devices/me"), roots, restored, later);
  assert.equal(result.authorized, true); assert.equal(result.grant.deviceID, record.deviceID);
  assert.equal(result.grant.tokenHash, undefined);
  const { invitation } = storage.persisted.get(invitePrefix + invitationID) ? { invitation: storage.persisted.get(invitePrefix + invitationID) } : {};
  await assert.rejects(redeemEnrollmentInvitation(await redemption(invitation, { time: later }), context("devices/enroll"), roots, restored, later), denied());
});

test("semantic grant equality does not depend on stored JSON key order", async () => {
  const storage = journal(), { invitation } = await create(storage);
  await redeemEnrollmentInvitation(await redemption(invitation), context("devices/enroll"), roots, storage, now);
  const document = storage.persisted.get(registryKey);
  document.grants[0] = Object.fromEntries(Object.entries(document.grants[0]).reverse());
  storage.persisted.set(registryKey, document);
  const result = await redeemEnrollmentInvitation(await redemption(invitation), context("devices/enroll"), roots, storage, now);
  assert.equal(result.alreadyEnrolled, true);
});

test("revoked owner or target cannot register or recover and tombstones remain monotonic", async () => {
  for (const device of [ownerRecord.deviceID, record.deviceID]) {
    const storage = journal(), { invitation } = await create(storage);
    storage.persisted.set(keys.revoked(device), { version: 1, by: ownerRecord.deviceID, revokedAt: now });
    await assert.rejects(redeemEnrollmentInvitation(await redemption(invitation), context("devices/enroll"), roots, storage, now), denied());
    assert.equal(storage.persisted.has(registryKey), false);
  }
  const storage = journal(); await enroll(storage);
  storage.persisted.set(keys.revoked(), { version: 1, by: ownerRecord.deviceID, revokedAt: now });
  await assert.rejects(readOwnEnrollment(await selfRequest(), context("devices/me"), roots, storage, now), denied());
});

test("an enrolled dynamic device can be explicitly revoked by its proven owner", async () => {
  const storage = journal(); await enroll(storage);
  const resource = `devices/${record.deviceID}/revoke`, uri = url(resource);
  const signed = await proof({ uri, key: ownerSigner, header: { jwk: ownerJWK }, nonce, claims: { ath: await tokenHash(ownerToken) } });
  const records = JSON.stringify(await enrolledDeviceRecords(storage, roots, context()));
  assert.equal((await revokeDevice(request(signed, { uri, accessToken: ownerToken }), context(resource), records, storage, record.deviceID, now)).revoked, true);
  await assert.rejects(readOwnEnrollment(await selfRequest(), context("devices/me"), roots, storage, now), denied());
});

test("second write failure rolls back both grant and consumed-invitation receipt", async () => {
  const storage = journal(), { invitation } = await create(storage), before = storage.snapshot();
  const transact = storage.transaction.bind(storage);
  storage.transaction = callback => transact(async tx => {
    let writes = 0;
    return callback({ ...tx, put: async (...args) => { if (++writes === 2) throw Error("injected second write"); return tx.put(...args); } });
  });
  await assert.rejects(redeemEnrollmentInvitation(await redemption(invitation), context("devices/enroll"), roots, storage, now), denied("device_auth_state_unavailable", 503));
  assert.deepEqual(storage.persisted, before);
  storage.transaction = transact;
  assert.equal((await redeemEnrollmentInvitation(await redemption(invitation), context("devices/enroll"), roots, storage, now)).alreadyEnrolled, false);
});

test("corrupt, foreign-scope and owner-role dynamic registries fail closed, not silently reset", async () => {
  for (const document of [{ version: 99 },
    { version: 1, roomID: record.roomID, keyID: record.keyID, grants: [{ ...record, roomID: "other" }] },
    { version: 1, roomID: record.roomID, keyID: record.keyID, grants: [ownerRecord] },
    { version: 1, roomID: record.roomID, keyID: record.keyID, grants: [null] }]) {
    const storage = journal(); storage.persisted.set(registryKey, document);
    await assert.rejects(enrolledDeviceRecords(storage, roots, context()), denied("device_auth_state_unavailable", 503));
    assert.deepEqual(storage.persisted.get(registryKey), document);
  }
});

test("owner pin changes, unknown invitations and storage read failures cannot enroll", async () => {
  const storage = journal(), { invitation } = await create(storage);
  await assert.rejects(redeemEnrollmentInvitation(await redemption(invitation, { body: { invitationID: "unknown" } }), context("devices/enroll"), roots, storage, now), denied("invalid_enrollment_invitation"));
  const changedRoots = JSON.stringify([{ ...ownerRecord, jwk }]);
  await assert.rejects(redeemEnrollmentInvitation(await redemption(invitation), context("devices/enroll"), changedRoots, storage, now), denied("invalid_enrollment_invitation"));
  storage.failRead = true;
  await assert.rejects(enrolledDeviceRecords(storage, roots, context()), denied("device_auth_state_unavailable", 503));
});

test("invitation immutable fields are checked again in the grant transaction", async () => {
  const storage = journal(), { invitation } = await create(storage), transact = storage.transaction.bind(storage);
  storage.transaction = callback => {
    const value = storage.persisted.get(invitePrefix + invitationID); value.role = "watch";
    storage.persisted.set(invitePrefix + invitationID, value); return transact(callback);
  };
  await assert.rejects(redeemEnrollmentInvitation(await redemption(invitation), context("devices/enroll"), roots, storage, now), denied("invalid_enrollment_invitation"));
  assert.equal(storage.persisted.has(registryKey), false);
});

test("expired or duplicate existing identity cannot be overwritten by a new invitation", async () => {
  const storage = journal(); await enroll(storage);
  const { invitation } = await create(storage, { invitationID: "new-invite" });
  const req = await redemption(invitation, { body: { invitationID: "new-invite" } });
  await assert.rejects(redeemEnrollmentInvitation(req, context("devices/enroll"), roots, storage, now), denied("enrolled_identity_conflict", 409));
  assert.equal(storage.persisted.get(invitePrefix + "new-invite").receipt, null);
});

test("oversize and malformed bodies are bounded before authorization/storage access", async () => {
  for (const [body, headers, code, status] of [["x".repeat(8193), {}, "enrollment_body_too_large", 413],
    ["{}", { "Content-Length": "9000" }, "enrollment_body_too_large", 413], ["not-json", {}, "invalid_enrollment_body", 400]]) {
    const storage = journal();
    await assert.rejects(createEnrollmentInvitation(new Request(url("devices/invitations"), { method: "POST", body, headers }),
      context("devices/invitations"), roots, storage, now), denied(code, status));
    assert.equal(storage.transactions, 0);
  }
});

test("live invitation capacity is bounded and corrupt rows or cleanup failures cannot be discarded silently", async () => {
  const base = journal(); await create(base);
  const sample = base.persisted.get(invitePrefix + invitationID);
  const make = count => {
    const storage = journal();
    for (let i = 0; i < count; i++) {
      const id = `invitation-${i}`; storage.persisted.set(invitePrefix + id, { ...sample, invitationID: id });
    }
    return storage;
  };
  await assert.rejects(create(make(64)), denied("enrollment_capacity", 429));
  await assert.rejects(create(make(65)), denied("device_auth_state_unavailable", 503));
  const corrupt = make(1); corrupt.persisted.set(invitePrefix + "invitation-0", { ...sample, version: 9 });
  await assert.rejects(create(corrupt), denied("device_auth_state_unavailable", 503));
  assert.equal(corrupt.persisted.get(invitePrefix + "invitation-0").version, 9);
  const expired = journal(); expired.persisted.set(invitePrefix + "old", { ...sample, invitationID: "old", issuedAt: now - 120_001, expiresAt: now - 1 });
  const transact = expired.transaction.bind(expired); let calls = 0;
  expired.transaction = callback => { if (++calls === 2) expired.failNext("delete"); return transact(callback); };
  await assert.rejects(create(expired), denied("device_auth_state_unavailable", 503));
  assert(expired.persisted.has(invitePrefix + "old")); assert(!expired.persisted.has(invitePrefix + invitationID));
});

test("grant-result query rechecks revocation after proof admission", async () => {
  const storage = journal(); await enroll(storage);
  storage.persisted.set(keys.nonce(), nonceRecord(nonce));
  const transact = storage.transaction.bind(storage); let calls = 0;
  storage.transaction = callback => {
    if (++calls === 2) storage.persisted.set(keys.revoked(), { version: 1, revokedAt: now, by: ownerRecord.deviceID });
    return transact(callback);
  };
  await assert.rejects(readOwnEnrollment(await selfRequest(nonce), context("devices/me"), roots, storage, now), denied());
});

test("slow body completion is checked against actual completion time, not request start", async () => {
  const storage = journal(), body = await createBody(); let time = now;
  const original = await ownerRequest(body), bytes = new TextEncoder().encode(JSON.stringify(body));
  let sent = false;
  const bodyStream = new ReadableStream({ pull(controller) {
    if (!sent) { sent = true; time = now + 121_000; controller.enqueue(bytes); } else controller.close();
  } }, { highWaterMark: 0 });
  const req = new Request(original, { body: bodyStream, duplex: "half" });
  // Exercise the production default clock, not only a supplied fake callback.
  const realNow = Date.now; Date.now = () => time;
  try { await assert.rejects(createEnrollmentInvitation(req, context("devices/invitations"), roots, storage), denied("enrollment_invitation_expired", 410)); }
  finally { Date.now = realNow; }
  assert.equal(storage.transactions, 0);
});

test("invitation creation cannot commit after expiry while waiting behind another transaction", async () => {
  const storage = journal(), body = await createBody(); let time = now, calls = 0;
  const transact = storage.transaction.bind(storage);
  storage.transaction = callback => { if (++calls === 2) time = now + 121_000; return transact(callback); };
  await assert.rejects(createEnrollmentInvitation(await ownerRequest(body), context("devices/invitations"), roots, storage, () => time), denied("enrollment_invitation_expired", 410));
  assert(!storage.persisted.has(invitePrefix + invitationID));
});

test("invitation creation rolls back when the original deadline passes during its storage write", async () => {
  const storage = journal(); let time = now;
  const transact = storage.transaction.bind(storage);
  storage.transaction = callback => transact(tx => callback({ ...tx, put: async (key, value) => {
    await tx.put(key, value);
    if (key.startsWith(invitePrefix)) time = value.expiresAt;
  } }));
  await assert.rejects(createEnrollmentInvitation(await ownerRequest(await createBody()), context("devices/invitations"),
    roots, storage, () => time), denied("enrollment_invitation_expired", 410));
  assert(!storage.persisted.has(invitePrefix + invitationID));
});

test("redemption rechecks expiry inside its queued commit, without consuming the invitation", async () => {
  const storage = journal(), { invitation } = await create(storage); let time = now;
  const transact = storage.transaction.bind(storage);
  storage.transaction = callback => { time = now + 121_000; return transact(callback); };
  await assert.rejects(redeemEnrollmentInvitation(await redemption(invitation), context("devices/enroll"), roots, storage, () => time), denied("invalid_enrollment_invitation"));
  assert(!storage.persisted.has(registryKey)); assert.equal(storage.persisted.get(invitePrefix + invitationID).receipt, null);
});

test("self lookup cannot return an expired grant after proof admission waited for its result transaction", async () => {
  const storage = journal(); await enroll(storage); storage.persisted.set(keys.nonce(), nonceRecord(nonce));
  let time = now, calls = 0; const transact = storage.transaction.bind(storage);
  storage.transaction = callback => { if (++calls === 2) time = now + 600_000; return transact(callback); };
  await assert.rejects(readOwnEnrollment(await selfRequest(nonce), context("devices/me"), roots, storage, () => time), denied());
});
