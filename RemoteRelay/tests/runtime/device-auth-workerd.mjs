import { DurableObject } from "cloudflare:workers";
import { calculateJwkThumbprint, importJWK, SignJWT } from "jose";
import { BODY_HASH_CLAIM, authorizeDevice, base64URL, bodyHash, revokeDevice, targetURI, tokenHash, verifyDeviceProof } from "../../src/device-auth.mjs";
import { createEnrollmentInvitation, enrolledDeviceRecords, readOwnEnrollment, redeemEnrollmentInvitation } from "../../src/device-enrollment.mjs";
import { verifyRelayEnvelope } from "../../src/signed-envelope.mjs";
import swiftFixture from "../fixtures/swift-signed-envelope.json";
import swiftEnrollment from "../fixtures/swift-enrollment.json";
import swiftKeyDelivery from "../fixtures/swift-key-delivery.json";
import relayWorker, { RelayRoom } from "../../src/index.js";
import { DeviceRelayOperations } from "../../src/device-relay.mjs";
import { deviceRoute } from "../../src/device-routing.mjs";

// Test-only class. Never import/export from the live Worker or add production
// bindings. The capnp test configuration has no sockets and no network access.
const now = 1_800_000_000_000, roomID = "qa-runtime", keyID = "a".repeat(32);
const url = resource => `https://relay.example/v3/rooms/${roomID}/${resource}`;
const assert = (condition, message) => { if (!condition) throw Error(message); };
const fromHex = value => Uint8Array.from(value.match(/../g), byte => parseInt(byte, 16));
const phoneJWK = { kty: "OKP", crv: "Ed25519", x: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo" };
const ownerJWK = { kty: "OKP", crv: "Ed25519", x: base64URL(fromHex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")) };
const phoneToken = base64URL(new Uint8Array(32).fill(93)), ownerToken = base64URL(new Uint8Array(32).fill(94));
async function fixtures() {
  const phone = { roomID, keyID, deviceID: "qa-phone", role: "phone", jwk: phoneJWK, tokenHash: await tokenHash(phoneToken), expiresAt: now + 3_600_000 };
  const owner = { ...phone, deviceID: "qa-owner", role: "mac", jwk: ownerJWK, tokenHash: await tokenHash(ownerToken) };
  return { records: JSON.stringify([phone, owner]), phone, owner };
}
async function signedRequest(resource = "mailbox/mac", { owner = false, method = "POST", nonce, jti = crypto.randomUUID(), body,
  accessToken, time = now } = {}) {
  // Published RFC 8032 seeds only; never account/device secrets.
  const jwk = owner ? ownerJWK : phoneJWK, token = accessToken ?? (owner ? ownerToken : phoneToken);
  const seed = owner ? "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb" : "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60";
  const key = await importJWK({ ...jwk, d: base64URL(fromHex(seed)) }, "Ed25519");
  const bytes = body === undefined ? undefined : JSON.stringify(body);
  const proof = await new SignJWT({ htm: method, htu: targetURI(url(resource)), iat: Math.floor(time / 1000), jti, ath: await tokenHash(token),
    ...(nonce === undefined ? {} : { nonce }), ...(bytes === undefined ? {} : { [BODY_HASH_CLAIM]: await bodyHash(new TextEncoder().encode(bytes)) })
  }).setProtectedHeader({ alg: "Ed25519", typ: "dpop+jwt", jwk }).sign(key);
  return { uri: url(resource), method, headers: { Authorization: `DPoP ${token}`, DPoP: proof, "X-Codex-Relay-Key-ID": keyID }, resource,
    ...(bytes === undefined ? {} : { body: bytes }) };
}
const request = value => new Request(value.uri, { method: value.method, headers: value.headers,
  ...(value.body === undefined ? {} : { body: value.body }) });
const context = value => ({ roomID, keyID, resource: value.resource });

// Test-only subclass of the ACTUAL exported room. The only replacement is a
// fixed QA clock; HTTP routing, role/proof checks, storage and WS code are real.
// Never export this class from production or bind it to an installed room.
export class RelayHTTPQARoom extends RelayRoom {
  constructor(ctx, env) { super(ctx, env); this.deviceRelay = new DeviceRelayOperations(ctx, env, () => now); }
  async runExpiredSocketAlarm() {
    const original = this.deviceRelay.clock;
    try { this.deviceRelay.clock = () => now + 3_600_000; await this.deviceRelay.alarm(); }
    finally { this.deviceRelay.clock = original; }
  }
  // Public synthetic nonce setup ONLY for replaying actual native proof bytes.
  // Random challenge generation remains covered by the independent HTTP tests.
  async seedSyntheticKeyDeliveryNonce() {
    assert(swiftKeyDelivery.synthetic === true && swiftKeyDelivery.now === now
      && swiftKeyDelivery.roots.length === 2 && swiftKeyDelivery.roots.every(peer => peer.roomID === "qa"
        && peer.keyID === "8795d57b31051f613c241a9052e3ce50"), "unknown native QA key scope");
    for (const peer of swiftKeyDelivery.roots) await this.ctx.storage.put(
      `device-auth:nonce:${peer.roomID}:${peer.keyID}:${peer.deviceID}`,
      { version: 1, nonce: base64URL(new Uint8Array(32).fill(23)), expiresAt: now + 120_000 });
  }
  async keyDeliveryCommitFault(mode) {
    assert(["request-expiry", "response-expiry", "grant-expiry"].includes(mode), "unknown bounded key fault");
    await this.seedSyntheticKeyDeliveryNonce();
    let time = now;
    const original = this.ctx.storage;
    const storage = { get: original.get.bind(original), list: original.list.bind(original),
      transaction: callback => original.transaction(transaction => callback({
        get: transaction.get.bind(transaction), list: transaction.list.bind(transaction), delete: transaction.delete.bind(transaction),
        put: async (key, value) => {
          await transaction.put(key, value);
          if (key.startsWith("device-key:") && (mode !== "response-expiry" || value.responseBytes)) {
            time = mode === "grant-expiry" ? swiftKeyDelivery.roots[1].expiresAt : swiftKeyDelivery.requestPacket.expiresAt;
          }
        },
      })),
    };
    const operations = new DeviceRelayOperations({ storage }, this.env, () => time);
    const send = wire => {
      const headers = new Headers(wire.headers); headers.set("X-Codex-Relay-Protocol", "3"); headers.set("X-Codex-Relay-Room", "qa");
      return operations.handle(new Request(wire.url, { method: wire.method, headers, ...(wire.body ? { body: wire.body } : {}) }));
    };
    let response = await send(swiftKeyDelivery.upload);
    if (mode === "response-expiry") {
      assert(response.status === 200, "response fault setup could not store native request");
      response = await send(swiftKeyDelivery.ownerReply);
    }
    const rows = await original.list({ prefix: "device-key:" });
    return { status: response.status, storedRequests: rows.size,
      storedResponses: [...rows.values()].filter(value => value.responseBytes !== null).length };
  }
  async invitationBusinessSnapshot(remember = false) {
    const rows = await this.ctx.storage.list({ prefix: `enrollment:invitation:${roomID}:${keyID}:` });
    const bytes = JSON.stringify([...rows]);
    if (remember) await this.ctx.storage.put("qa:original-invitation-rows", bytes);
    return { current: bytes, original: await this.ctx.storage.get("qa:original-invitation-rows") };
  }
  async invitationTimingFault(wire, mode) {
    assert(["create-expiry", "read-expiry", "read-owner-expiry", "create-return-expiry", "read-return-expiry"].includes(mode), "unknown invitation QA timing fault");
    let time = now;
    const original = this.ctx.storage, prefix = `enrollment:invitation:${roomID}:${keyID}:`;
    const storage = { get: original.get.bind(original), transaction: async callback => {
      let invitationTouched = false;
      const result = await original.transaction(tx => callback({
      list: tx.list.bind(tx), delete: tx.delete.bind(tx),
      get: async key => {
        const value = await tx.get(key);
        if (key.startsWith(prefix)) {
          invitationTouched = true;
          if (mode === "read-expiry" || mode === "read-owner-expiry") time = mode === "read-expiry" ? now + 120_000 : now + 3_600_000;
        }
        return value;
      },
      put: async (key, value) => { await tx.put(key, value); if (key.startsWith(prefix) && mode === "create-expiry") time = value.expiresAt; },
      }));
      // Advance only AFTER the real SQLite transaction promise resolves.
      // This is separate from the put-await rollback fault above.
      if (invitationTouched && mode.endsWith("-return-expiry")) time = now + 120_000;
      return result;
    } };
    const headers = new Headers(wire.headers); headers.set("X-Codex-Relay-Protocol", "3"); headers.set("X-Codex-Relay-Room", roomID);
    const operations = new DeviceRelayOperations({ storage }, this.env, () => time);
    const response = await operations.handle(new Request(wire.uri, { method: wire.method, headers, ...(wire.body ? { body: wire.body } : {}) }));
    return { status: response.status, rows: JSON.stringify([...(await original.list({ prefix }))]) };
  }
}

export class RelayAuthQARoom extends DurableObject {
  async createInvitation(value, roots) {
    try { return await createEnrollmentInvitation(request(value), context(value), roots, this.ctx.storage, now); }
    catch (error) { return { error: error.code ?? "unexpected_error", status: error.status ?? 500 }; }
  }
  async enroll(value, roots, failSecondWrite = false) {
    let storage = this.ctx.storage;
    if (failSecondWrite) storage = {
      get: this.ctx.storage.get.bind(this.ctx.storage),
      transaction: callback => this.ctx.storage.transaction(transaction => {
        let writes = 0;
        return callback({ get: transaction.get.bind(transaction), list: transaction.list.bind(transaction),
          delete: transaction.delete.bind(transaction), put: async (...args) => {
            if (++writes === 2) throw Error("injected second enrollment write");
            return transaction.put(...args);
          } });
      }),
    };
    try { return await redeemEnrollmentInvitation(request(value), context(value), roots, storage, now); }
    catch (error) { return { error: error.code ?? "unexpected_error", status: error.status ?? 500 }; }
  }
  async ownGrant(value, roots, time = now) {
    try { return await readOwnEnrollment(request(value), context(value), roots, this.ctx.storage, time); }
    catch (error) { return { error: error.code ?? "unexpected_error", status: error.status ?? 500 }; }
  }
  async enrolledRecords(roots) {
    return JSON.stringify(await enrolledDeviceRecords(this.ctx.storage, roots, { roomID, keyID }));
  }
  async enrollmentState() {
    const document = await this.ctx.storage.get(`enrollment:registry:${roomID}:${keyID}:`);
    const invites = await this.ctx.storage.list({ prefix: `enrollment:invitation:${roomID}:${keyID}:` });
    return { grants: document?.grants.length ?? 0, consumed: [...invites.values()].filter(value => value.receipt !== null).length };
  }
  async authorize(value, records, failWrites = false) {
    let storage = this.ctx.storage;
    if (failWrites) storage = { transaction: callback => this.ctx.storage.transaction(transaction => callback({
      get: transaction.get.bind(transaction), list: transaction.list.bind(transaction), delete: transaction.delete.bind(transaction),
      put: async () => { throw Error("injected QA put failure"); },
    })) };
    try { return await authorizeDevice(request(value), context(value), records, storage, now); }
    catch (error) { return { error: error.code ?? "unexpected_error", status: error.status ?? 500 }; }
  }
  async revoke(value, records, deviceID) {
    try { return await revokeDevice(request(value), context(value), records, this.ctx.storage, deviceID, now); }
    catch (error) { return { error: error.code ?? "unexpected_error", status: error.status ?? 500 }; }
  }
  async state() {
    const replays = await this.ctx.storage.list({ prefix: "device-auth:replay:" });
    const revoked = await this.ctx.storage.list({ prefix: "device-auth:revoked:" });
    return { replayRows: replays.size, revokedRows: revoked.size };
  }
  async rememberExactTestRequest(value, records) {
    await this.ctx.storage.put("qa:stored-original", { value, records });
  }
  async retryExactStoredRequest() {
    const stored = await this.ctx.storage.get("qa:stored-original");
    assert(!!stored, "first process did not persist the exact test request");
    return this.authorize(stored.value, stored.records);
  }
  async rollbackProbe() {
    try {
      await this.ctx.storage.transaction(async transaction => {
        await transaction.put("qa:must-not-commit", true);
        throw Error("intentional rollback");
      });
    } catch { /* expected test-only failure */ }
    return (await this.ctx.storage.get("qa:must-not-commit")) === undefined;
  }
}

async function challenge(stub, records, options = {}) {
  const value = await signedRequest(options.resource, options);
  const result = await stub.authorize(value, records);
  assert(result.authorized === false && /^[A-Za-z0-9_-]{43}$/.test(result.nonce), "must obtain a real stored challenge, not authorization");
  return result.nonce;
}

const cryptoInterop = { async test() {
  const result = await verifyRelayEnvelope(swiftFixture.compactJWS, swiftFixture.identity,
    { roomID: swiftFixture.identity.roomID, keyID: swiftFixture.identity.keyID, destination: swiftFixture.destination }, swiftFixture.now);
  assert(result.originalSHA256 === swiftFixture.originalSHA256, "actual workerd did not verify the Swift original");
  assert(await calculateJwkThumbprint(phoneJWK) === "kPrK_qmxVWaYVA9wwBF6Iuo3vVzz7TxHCTwXBygrS4k", "thumbprint mismatch");
} };

const enrollmentCryptoInterop = { async test() {
  const value = swiftEnrollment;
  assert(value.synthetic === true && value.record.jwk.x === phoneJWK.x, "not the known synthetic native enrollment");
  const request = new Request(value.uri, { method: value.method, body: value.body,
    headers: { Authorization: value.authorization, DPoP: value.proof, "X-Codex-Relay-Key-ID": value.keyIDHeader } });
  assert(value.keyIDHeader === value.record.keyID, "native request omitted epoch routing");
  const result = await verifyDeviceProof(request, { ...deviceRoute(request),
    bodyDigest: await bodyHash(new TextEncoder().encode(value.body)) }, JSON.stringify([value.record]), value.now);
  assert(result.nonce === value.nonce && result.principal.deviceID === "qa-phone", "native enrollment body proof did not verify in actual workerd");
} };

const persistentReplayFirst = { async test(ctrl, env) {
  const stub = env.AUTH_QA.getByName("qa-persistent-replay"), { records } = await fixtures();
  const nonce = await challenge(stub, records);
  const value = await signedRequest("mailbox/mac", { nonce });
  assert((await stub.authorize(value, records)).authorized === true, "first proof was not authorized");
  assert((await stub.authorize(value, records)).error === "dpop_proof_replayed", "same-process proof replay accepted");
  await stub.rememberExactTestRequest(value, records);
  assert((await stub.state()).replayRows === 1, "expected one stored proof");
} };

const persistentReplayAfterRestart = { async test(ctrl, env) {
  const stub = env.AUTH_QA.getByName("qa-persistent-replay");
  const result = await stub.retryExactStoredRequest();
  assert(result.error === "dpop_proof_replayed", "exact previous-process proof was accepted after runtime restart");
  assert((await stub.state()).replayRows === 1, "proof rows did not persist across process boundary");
} };

const concurrentReplay = { async test(ctrl, env) {
  const stub = env.AUTH_QA.getByName("qa-concurrent-replay"), { records } = await fixtures();
  const nonce = await challenge(stub, records), value = await signedRequest("mailbox/mac", { nonce });
  const results = await Promise.all(Array.from({ length: 16 }, () => stub.authorize(value, records)));
  assert(results.filter(value => value.authorized === true).length === 1, "concurrent replay committed more than once");
  assert(results.filter(value => value.error === "dpop_proof_replayed").length === 15, "unexpected concurrent replay outcomes");
  assert((await stub.state()).replayRows === 1, "concurrent proof rows disagree");
} };

const durableRevocation = { async test(ctrl, env) {
  const stub = env.AUTH_QA.getByName("qa-revocation"), { records } = await fixtures();
  const resource = "devices/qa-phone/revoke";
  const nonce = await challenge(stub, records, { resource, owner: true });
  const result = await stub.revoke(await signedRequest(resource, { owner: true, nonce }), records, "qa-phone");
  assert(result.revoked === true, "owner revocation did not commit");
  const denied = await stub.authorize(await signedRequest(), records);
  assert(denied.status === 401 && denied.authorized !== true, "revoked target was granted a new challenge/access");
  assert((await stub.state()).revokedRows === 1, "revocation tombstone missing");
} };

const rollbackAndWriteFailure = { async test(ctrl, env) {
  const stub = env.AUTH_QA.getByName("qa-storage-failure"), { records } = await fixtures();
  assert(await stub.rollbackProbe(), "real DO transaction failed to roll back");
  const nonce = await challenge(stub, records), value = await signedRequest("mailbox/mac", { nonce });
  const result = await stub.authorize(value, records, true);
  assert(result.error === "device_auth_state_unavailable" && result.status === 503, "injected write failure granted access or returned wrong status");
  assert((await stub.state()).replayRows === 0, "failed proof write persisted a false reservation");
  assert((await stub.authorize(value, records)).authorized === true, "failed rolled-back request could not be safely checked again");
} };

const mobileRoleCannotEscalate = { async test(ctrl, env) {
  const stub = env.AUTH_QA.getByName("qa-role"), { records } = await fixtures();
  const result = await stub.authorize(await signedRequest("snapshot", { method: "PUT" }), records);
  assert(result.status === 403 && result.error === "device_role_forbidden", "mobile snapshot-write was accepted");
  assert((await stub.state()).replayRows === 0, "forbidden role wrote proof state");
} };

const inviteToken = base64URL(new Uint8Array(32).fill(95));
async function setupEnrollment(stub) {
  const { owner } = await fixtures(), roots = JSON.stringify([owner]);
  const nonce = await challenge(stub, roots, { owner: true, resource: "devices/invitations" });
  const body = { invitationID: "runtime-invitation", role: "phone", secretHash: await tokenHash(inviteToken),
    expiresAt: now + 120_000, grantExpiresAt: now + 600_000 };
  const result = await stub.createInvitation(await signedRequest("devices/invitations", { owner: true, nonce, body }), roots);
  assert(result.authorized === true && !result.invitation.consumed, "owner invitation was not durably created");
  const enrolledBody = { invitationID: body.invitationID, deviceID: "qa-phone", jwk: phoneJWK, tokenHash: await tokenHash(phoneToken) };
  const value = await signedRequest("devices/enroll", { accessToken: inviteToken, nonce: result.invitation.nonce, body: enrolledBody });
  return { roots, value };
}

const enrollmentConcurrentAndReceipt = { async test(ctrl, env) {
  const stub = env.AUTH_QA.getByName("qa-enrollment-persisted"), { roots, value } = await setupEnrollment(stub);
  const results = await Promise.all(Array.from({ length: 16 }, () => stub.enroll(value, roots)));
  assert(results.filter(value => value.enrolled === true && !value.alreadyEnrolled).length === 1, "enrollment did not commit exactly once");
  assert(results.filter(value => value.alreadyEnrolled === true).length === 15, "exact enrollment retries did not read original receipt");
  const state = await stub.enrollmentState();
  assert(state.grants === 1 && state.consumed === 1, "grant and receipt are not atomic");
  assert(results.every(value => value.grant.tokenHash === undefined), "public response exposed access token hash");
} };

const enrollmentRollback = { async test(ctrl, env) {
  const stub = env.AUTH_QA.getByName("qa-enrollment-rollback"), { roots, value } = await setupEnrollment(stub);
  const result = await stub.enroll(value, roots, true);
  assert(result.error === "device_auth_state_unavailable" && result.status === 503, "write failure reported successful enrollment");
  const state = await stub.enrollmentState();
  assert(state.grants === 0 && state.consumed === 0, "partial enrollment survived real SQLite rollback");
  assert((await stub.enroll(value, roots)).alreadyEnrolled === false, "rolled-back invitation could not be consumed once");
} };

const enrollmentRevocation = { async test(ctrl, env) {
  const stub = env.AUTH_QA.getByName("qa-enrollment-revoke"), { roots, value } = await setupEnrollment(stub);
  assert((await stub.enroll(value, roots)).enrolled === true, "setup enrollment failed");
  const resource = "devices/qa-phone/revoke", records = await stub.enrolledRecords(roots);
  const nonce = await challenge(stub, records, { resource, owner: true });
  assert((await stub.revoke(await signedRequest(resource, { owner: true, nonce }), records, "qa-phone")).revoked === true, "dynamic grant could not be revoked");
  assert((await stub.ownGrant(await signedRequest("devices/me", { method: "GET" }), roots)).status === 401, "revoked grant was restored by self lookup");
  assert((await stub.enroll(value, roots)).status === 401, "replaying consumed invite restored revoked grant");
} };

const enrollmentAfterProcessRestart = { async test(ctrl, env) {
  const stub = env.AUTH_QA.getByName("qa-enrollment-persisted"), { owner } = await fixtures();
  const roots = JSON.stringify([owner]), later = now + 121_000;
  const challenge = await stub.ownGrant(await signedRequest("devices/me", { method: "GET", time: later }), roots, later);
  assert(challenge.authorized === false && !!challenge.nonce, "newly enrolled identity did not survive independent runtime restart");
  const result = await stub.ownGrant(await signedRequest("devices/me", { method: "GET", time: later, nonce: challenge.nonce }), roots, later);
  assert(result.authorized === true && result.grant.deviceID === "qa-phone", "lost ACK recovery failed after invitation expiry");
  const state = await stub.enrollmentState();
  assert(state.grants === 1 && state.consumed === 1, "recovery mutated the original enrollment");
} };

const httpPacket = (destination, id, overrides = {}) => ({ version: 3, keyID, destination, id, sentAt: now,
  expiresAt: now + 60_000, sealed: btoa(String.fromCharCode(...new Uint8Array(60).fill(7))), ...overrides });
const http = async (env, resource, options = {}) => relayWorker.fetch(request(await signedRequest(resource, options)), env);
async function httpNonce(env, resource, options = {}) {
  const response = await http(env, resource, options);
  assert(response.status === 401 && !!response.headers.get("DPoP-Nonce"), "real HTTP did not return a nonce-only challenge");
  assert((await response.json()).error === "use_dpop_nonce", "challenge was a false successful admission");
  return response.headers.get("DPoP-Nonce");
}

const actualHTTPDeliveryAndIdempotentACK = { async test(ctrl, env) {
  const body = httpPacket("mac", "http-original");
  const phoneNonce = await httpNonce(env, "mailbox/mac", { body });
  const accepted = await http(env, "mailbox/mac", { nonce: phoneNonce, body });
  assert(accepted.status === 200, "actual Worker/DO packet admission failed");
  assert((await accepted.json()).delivery === "queued", "queue ACK incorrectly implies execution");
  const macNonce = await httpNonce(env, "mailbox/mac", { owner: true, method: "GET" });
  const page = await (await http(env, "mailbox/mac", { owner: true, method: "GET", nonce: macNonce })).json();
  assert(page.packets.length === 1 && page.packets[0].id === body.id, "actual SQLite mailbox did not retain the original");
  for (let i = 0; i < 2; i++) assert((await http(env, "mailbox/mac/" + body.id, { owner: true, method: "DELETE", nonce: macNonce })).status === 204, "repeated ACK failed");
  const duplicate = await (await http(env, "mailbox/mac", { body, nonce: phoneNonce })).json();
  assert(duplicate.duplicate === true && duplicate.delivery === "acknowledged", "lost queue ACK resurrected an acknowledged packet");
  const changed = await http(env, "mailbox/mac", { nonce: phoneNonce, body: { ...body, expiresAt: body.expiresAt + 1 } });
  assert(changed.status === 409, "packet ID silently changed or deadline extended");
} };

const actualHTTPPagination = { async test(ctrl, env) {
  const phoneNonce = await httpNonce(env, "mailbox/mac", { body: httpPacket("mac", "http-unused-challenge") });
  const expected = ["http-z-first", "http-a-second", ...Array.from({ length: 17 }, (_, index) => "http-ordered-" + index)];
  for (const id of expected) assert((await http(env, "mailbox/mac", { body: httpPacket("mac", id), nonce: phoneNonce })).status === 200, "ordered POST failed");
  const macNonce = await httpNonce(env, "mailbox/mac", { owner: true, method: "GET" });
  const ids = []; let cursor;
  do {
    const response = await http(env, "mailbox/mac" + (cursor ? "?cursor=" + cursor : ""), { owner: true, method: "GET", nonce: macNonce });
    const page = await response.json();
    assert(response.status === 200 && Array.isArray(page.packets), "HTTP page failed: " + (page.error ?? response.status));
    assert(page.packets.length <= 8, "mailbox was not bounded"); ids.push(...page.packets.map(value => value.id)); cursor = page.nextCursor;
  } while (cursor);
  assert(JSON.stringify(ids) === JSON.stringify(expected), "actual HTTP pagination skipped, duplicated or reordered originals");
} };

const actualHTTPPersistedReceiptFirst = { async test(ctrl, env) {
  const body = httpPacket("phone", "http-restart-original");
  const macNonce = await httpNonce(env, "mailbox/phone", { owner: true, body });
  assert((await http(env, "mailbox/phone", { owner: true, body, nonce: macNonce })).status === 200, "persisted original POST failed");
  const phoneNonce = await httpNonce(env, "mailbox/phone", { method: "GET" });
  assert((await http(env, "mailbox/phone/" + body.id, { method: "DELETE", nonce: phoneNonce })).status === 204, "persisted original ACK failed");
} };

const actualHTTPPersistedReceiptAfterRestart = { async test(ctrl, env) {
  const body = httpPacket("phone", "http-restart-original"), macNonce = await httpNonce(env, "mailbox/phone", { owner: true, body });
  const result = await (await http(env, "mailbox/phone", { owner: true, body, nonce: macNonce })).json();
  assert(result.stored === true && result.duplicate === true && result.delivery === "acknowledged", "actual HTTP resurrected an ACKed original after process restart");
} };

const actualHTTPInvitationAndLegacyBoundary = { async test(ctrl, env) {
  const body = { invitationID: "http-only-invitation", role: "watch", secretHash: await tokenHash(inviteToken),
    expiresAt: now + 120_000, grantExpiresAt: now + 600_000 };
  const ownerNonce = await httpNonce(env, "devices/invitations", { owner: true, body });
  const first = await (await http(env, "devices/invitations", { owner: true, body, nonce: ownerNonce })).json();
  const again = await (await http(env, "devices/invitations", { owner: true, body, nonce: ownerNonce })).json();
  assert(first.authorized === true && first.invitation.ownerID === "qa-owner" && first.invitation.nonce === again.invitation.nonce, "real enrollment endpoint recreated a single-use invitation");
  assert((await http(env, "devices/invitations", { body })).status === 403, "phone became an enrollment owner");
  for (const protocol of [1, 2]) {
    const response = await relayWorker.fetch(new Request(`https://relay.example/v${protocol}/rooms/${roomID}/snapshot`), env);
    assert(response.status === 426, "coordinated migrated room fell back to a legacy credential route");
  }
  // A prior Worker can still call the updated object during version handoff.
  // Enforce cutover INSIDE the DO too, not only the current outer Worker.
  const oldWorkerStub = env.RELAY_ROOMS.getByName(`v2:${roomID}:${keyID}`);
  const internal = new Request("https://relay.example/snapshot", { headers: {
    "X-Codex-Relay-Protocol": "2", "X-Codex-Relay-Room": roomID, "X-Codex-Relay-Key-ID": keyID } });
  assert((await oldWorkerStub.fetch(internal)).status === 426, "updated object accepted an old Worker's migrated-room request");
  const missing = new Request("https://relay.example/snapshot", { headers: { "X-Codex-Relay-Protocol": "2" } });
  assert((await oldWorkerStub.fetch(missing)).status === 503, "missing old-Worker room context silently bypassed cutover");
  const malicious = await signedRequest("mailbox/mac", { body: httpPacket("mac", "http-altered") });
  malicious.body += " "; // Valid JSON with changed actual bytes but old proof.
  assert((await relayWorker.fetch(request(malicious), env)).status === 401, "body-bound proof accepted altered HTTP bytes");
} };

const originalInvitationBody = async () => ({ invitationID: "http-only-invitation", role: "watch", secretHash: await tokenHash(inviteToken),
  expiresAt: now + 120_000, grantExpiresAt: now + 600_000 });
const invitationQueryResource = "devices/invitations/http-only-invitation";
async function readHTTPInvitation(env) {
  const nonce = await httpNonce(env, invitationQueryResource, { owner: true, method: "GET" });
  const response = await http(env, invitationQueryResource, { owner: true, method: "GET", nonce });
  assert(response.status === 200, "known-ID invitation recovery failed through real Worker/DO");
  const result = await response.json();
  assert(result.authorized === true && result.invitation.invitationID === "http-only-invitation"
    && result.invitation.role === "watch" && result.invitation.consumed === false,
    "known-ID recovery returned a new or consumed authorization");
  assert(result.createDigest === await bodyHash(new TextEncoder().encode(JSON.stringify(await originalInvitationBody()))),
    "invitation recovery did not bind exact original create bytes");
  const text = JSON.stringify(result);
  assert(!text.includes(inviteToken) && !text.includes("secretHash") && !text.includes(ownerToken) && !text.includes("tokenHash"),
    "recovery exposed secret material");
  return { nonce, result };
}
const actualHTTPInvitationReceiptQuery = { async test(ctrl, env) {
  const stub = env.RELAY_ROOMS.getByName(`v3:${roomID}:${keyID}`);
  const before = await stub.invitationBusinessSnapshot(true);
  const { nonce, result } = await readHTTPInvitation(env);
  const absent = await http(env, "devices/invitations/not-created", { owner: true, method: "GET", nonce });
  assert(absent.status === 204 && await absent.text() === "", "absent invitation became false HTTP 200 success");
  const repeated = await http(env, invitationQueryResource, { owner: true, method: "GET", nonce });
  assert(repeated.status === 200 && JSON.stringify(await repeated.json()) === JSON.stringify(result), "read changed original nonce/deadline");
  assert((await http(env, invitationQueryResource, { owner: true, method: "DELETE", nonce })).status === 403, "recovery route authorized deletion");
  assert((await http(env, invitationQueryResource, { method: "GET" })).status === 403, "phone could query owner invitation");
  assert((await stub.invitationBusinessSnapshot()).current === before.current, "query altered invitation business rows");
} };
const actualHTTPInvitationQueryAfterRestart = { async test(ctrl, env) {
  await readHTTPInvitation(env);
  const state = await env.RELAY_ROOMS.getByName(`v3:${roomID}:${keyID}`).invitationBusinessSnapshot();
  assert(state.original !== undefined && state.current === state.original, "invitation read/restart changed original stored rows");
} };
const actualInvitationCreationExpiryRollback = { async test(ctrl, env) {
  const stub = env.RELAY_ROOMS.getByName("qa-invitation-create-expiry");
  const headers = { "X-Codex-Relay-Protocol": "3", "X-Codex-Relay-Room": roomID };
  const challengeWire = await signedRequest("devices/invitations/never-created", { owner: true, method: "GET" });
  const challengeResponse = await stub.fetch(new Request(request(challengeWire), { headers: { ...challengeWire.headers, ...headers } }));
  assert(challengeResponse.status === 401, "creation rollback setup did not get challenge");
  const wire = await signedRequest("devices/invitations", { owner: true, nonce: challengeResponse.headers.get("DPoP-Nonce"), body: await originalInvitationBody() });
  const result = await stub.invitationTimingFault(wire, "create-expiry");
  assert(result.status === 410 && result.rows === "[]", "real SQLite retained invitation expiring during create write");
} };
const actualInvitationQueryExpiry = { async test(ctrl, env) {
  const stub = env.RELAY_ROOMS.getByName(`v3:${roomID}:${keyID}`), { nonce } = await readHTTPInvitation(env);
  for (const [mode, status] of [["read-expiry", 410], ["read-owner-expiry", 401]]) {
    const wire = await signedRequest(invitationQueryResource, { owner: true, method: "GET", nonce });
    const result = await stub.invitationTimingFault(wire, mode);
    assert(result.status === status, "query disclosed invitation after its original grant/deadline expired");
    assert(result.rows === (await stub.invitationBusinessSnapshot()).original, "expired lookup altered original business state");
  }
} };
const actualInvitationReturnExpiry = { async test(ctrl, env) {
  const existing = env.RELAY_ROOMS.getByName(`v3:${roomID}:${keyID}`), { nonce } = await readHTTPInvitation(env);
  const read = await existing.invitationTimingFault(await signedRequest(invitationQueryResource, { owner: true, method: "GET", nonce }), "read-return-expiry");
  assert(read.status === 410 && read.rows === (await existing.invitationBusinessSnapshot()).original,
    "late query transaction return disclosed expired invitation or changed business state");
  const fresh = env.RELAY_ROOMS.getByName("qa-invitation-create-return-expiry");
  const wire = await signedRequest("devices/invitations/not-created", { owner: true, method: "GET" });
  const challenge = await fresh.fetch(new Request(request(wire), { headers: { ...wire.headers, "X-Codex-Relay-Protocol": "3", "X-Codex-Relay-Room": roomID } }));
  assert(challenge.status === 401, "late creation return setup has no nonce");
  const result = await fresh.invitationTimingFault(await signedRequest("devices/invitations", { owner: true,
    nonce: challenge.headers.get("DPoP-Nonce"), body: await originalInvitationBody() }), "create-return-expiry");
  const rows = JSON.parse(result.rows);
  assert(result.status === 410 && rows.length === 1 && rows[0][1].expiresAt === now + 120_000,
    "late committed invitation was reported usable or deleted/recreated instead of preserving its original result");
} };

const actualHTTPUnmigratedV2Compatibility = { async test(ctrl, env) {
  const legacyToken = btoa(String.fromCharCode(...new Uint8Array(32).fill(93)));
  const legacyEnv = { ...env, RELAY_V3_ONLY_ROOMS: undefined,
    RELAY_AUTH_V2: JSON.stringify([{ roomID: "qa-classic", keyID, authToken: legacyToken }]) };
  const at = Date.now(), body = { version: 2, keyID, destination: "snapshot", id: "classic-original", sentAt: at,
    expiresAt: at + 60_000, sealed: httpPacket("snapshot", "unused").sealed };
  const headers = { "X-Codex-Relay-Key": legacyToken, "X-Codex-Relay-Key-ID": keyID };
  const uri = "https://relay.example/v2/rooms/qa-classic/snapshot";
  const written = await relayWorker.fetch(new Request(uri, { method: "PUT", headers, body: JSON.stringify(body) }), legacyEnv);
  assert(written.status === 200, "adding v3 broke unmigrated v2 admission");
  const read = await relayWorker.fetch(new Request(uri, { headers }), legacyEnv);
  assert(read.status === 200 && (await read.json()).id === body.id, "v2 stored snapshot changed or disappeared");
  const denied = await relayWorker.fetch(new Request(uri, { headers: { ...headers, "X-Codex-Relay-Key": "wrong" } }), legacyEnv);
  assert(denied.status === 401, "unmigrated v2 bypassed its original authentication");
} };

function socketEvent(socket, type) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(Error("bounded QA socket event timeout: " + type)), 1500);
    socket.addEventListener(type, event => { clearTimeout(timer); resolve(event); }, { once: true });
  });
}
const actualHTTPWebSocketRevocation = { async test(ctrl, env) {
  const nonce = await httpNonce(env, "stream/phone", { method: "GET" });
  const value = await signedRequest("stream/phone", { method: "GET", nonce }); value.headers.Upgrade = "websocket";
  const response = await relayWorker.fetch(request(value), env);
  assert(response.status === 101 && !!response.webSocket, "real HTTP did not establish an authenticated WebSocket");
  const socket = response.webSocket; socket.accept();
  const pong = socketEvent(socket, "message"); socket.send("ping");
  assert((await pong).data === "pong", "authenticated socket did not recheck and answer its ping");
  const resource = "devices/qa-phone/revoke", ownerNonce = await httpNonce(env, resource, { owner: true });
  const [revocation, close] = await Promise.all([http(env, resource, { owner: true, nonce: ownerNonce }), socketEvent(socket, "close")]);
  assert(revocation.status === 200 && close.code === 1008, "revocation did not close the existing real socket");
  assert((await http(env, "snapshot", { method: "GET", nonce })).status === 401, "revoked stream identity could still read HTTP");
  const ownerReadNonce = await httpNonce(env, "mailbox/mac", { owner: true, method: "GET" });
  const page = await (await http(env, "mailbox/mac", { owner: true, method: "GET", nonce: ownerReadNonce })).json();
  assert(page.packets.length === 0 && page.rejected.length === 8, "revoked producer's first bounded queue page was still delivered");
} };

const actualHTTPIdleExpiryClosesSocket = { async test(ctrl, env) {
  const nonce = await httpNonce(env, "stream/mac", { owner: true, method: "GET" });
  const value = await signedRequest("stream/mac", { owner: true, method: "GET", nonce }); value.headers.Upgrade = "websocket";
  const response = await relayWorker.fetch(request(value), env);
  assert(response.status === 101 && response.webSocket, "idle-expiry setup could not establish the real owner socket");
  const socket = response.webSocket; socket.accept();
  const stub = env.RELAY_ROOMS.getByName(`v3:${roomID}:${keyID}`);
  const [, close] = await Promise.all([stub.runExpiredSocketAlarm(), socketEvent(socket, "close")]);
  assert(close.code === 1008, "the real expiry handler left an idle expired connection open");
} };

const keyWire = wire => new Request(wire.url, { method: wire.method, headers: wire.headers, ...(wire.body ? { body: wire.body } : {}) });
const actualHTTPNativeKeyDelivery = { async test(ctrl, env) {
  const value = swiftKeyDelivery;
  const stub = env.RELAY_ROOMS.getByName(`v3:qa:${value.roots[0].keyID}`);
  await stub.seedSyntheticKeyDeliveryNonce();
  const send = wire => relayWorker.fetch(keyWire(wire), env);
  assert((await send(value.upload)).status === 200, "actual native key-request proof/body was rejected");
  assert((await (await send(value.uploadAgain)).json()).duplicate === true, "native frozen request duplicated");
  assert(await (await send(value.queryRequest)).text() === value.upload.body, "actual key storage changed native original bytes");
  const listed = await (await send(value.ownerList)).json();
  assert(listed.requests.length === 1 && listed.requests[0].packet === base64URL(new TextEncoder().encode(value.upload.body)), "owner did not receive exact opaque native request");
  assert((await send(value.ownerReply)).status === 200, "actual native key-response proof/body was rejected");
  assert((await (await send(value.ownerReplyAgain)).json()).duplicate === true, "native frozen response duplicated");
  assert(await (await send(value.queryResponse)).text() === value.ownerReply.body, "real key reply did not retain exact native ciphertext");
} };
const actualHTTPNativeKeyDeliveryAfterRestart = { async test(ctrl, env) {
  assert(await (await relayWorker.fetch(keyWire(swiftKeyDelivery.queryResponseAfterRestart), env)).text() === swiftKeyDelivery.ownerReply.body,
    "native key response did not survive independent runtime restart");
  assert(await (await relayWorker.fetch(keyWire(swiftKeyDelivery.ownerQuery), env)).text() === swiftKeyDelivery.ownerReply.body,
    "owner receipt recovery changed the persisted native response");
} };
const actualKeyRequestExpiryRollback = { async test(ctrl, env) {
  const result = await env.RELAY_ROOMS.getByName("qa-key-request-expiry").keyDeliveryCommitFault("request-expiry");
  assert(result.status === 410 && result.storedRequests === 0, "real SQLite retained a key request expiring during commit");
} };
const actualKeyResponseExpiryRollback = { async test(ctrl, env) {
  const result = await env.RELAY_ROOMS.getByName("qa-key-response-expiry").keyDeliveryCommitFault("response-expiry");
  assert(result.status === 410 && result.storedRequests === 1 && result.storedResponses === 0, "real SQLite retained a key response expiring during commit");
} };
const actualKeyGrantExpiryRollback = { async test(ctrl, env) {
  const result = await env.RELAY_ROOMS.getByName("qa-key-grant-expiry").keyDeliveryCommitFault("grant-expiry");
  assert(result.status === 401 && result.storedRequests === 0, "real SQLite accepted an expired identity during key commit");
} };

export const phaseOne = { async test(ctrl, env, ctx) {
  for (const [name, item] of Object.entries({ cryptoInterop, enrollmentCryptoInterop, persistentReplayFirst, concurrentReplay,
    durableRevocation, rollbackAndWriteFailure, mobileRoleCannotEscalate,
    enrollmentConcurrentAndReceipt, enrollmentRollback, enrollmentRevocation,
    actualHTTPDeliveryAndIdempotentACK, actualHTTPPagination, actualHTTPPersistedReceiptFirst,
    actualHTTPInvitationAndLegacyBoundary, actualHTTPInvitationReceiptQuery, actualInvitationCreationExpiryRollback, actualInvitationQueryExpiry, actualInvitationReturnExpiry,
    actualHTTPUnmigratedV2Compatibility, actualHTTPWebSocketRevocation,
    actualHTTPIdleExpiryClosesSocket, actualHTTPNativeKeyDelivery, actualKeyRequestExpiryRollback,
    actualKeyResponseExpiryRollback, actualKeyGrantExpiryRollback })) {
    await item.test(ctrl, env, ctx);
    console.log(JSON.stringify({ test: name, passed: true }));
  }
} };
export const phaseTwo = { async test(ctrl, env, ctx) {
  for (const [name, item] of Object.entries({ persistentReplayAfterRestart, enrollmentAfterProcessRestart, actualHTTPPersistedReceiptAfterRestart,
    actualHTTPNativeKeyDeliveryAfterRestart, actualHTTPInvitationQueryAfterRestart })) {
    await item.test(ctrl, env, ctx);
    console.log(JSON.stringify({ test: name, passed: true }));
  }
} };
