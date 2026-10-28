import { importJWK, SignJWT } from "jose";
import { base64URL, targetURI, tokenHash } from "../../src/device-auth.mjs";

// Public RFC 8032 seed; this is not a user key, account token or live room.
export const jwk = { kty: "OKP", crv: "Ed25519", x: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo" };
const seed = Uint8Array.from(Buffer.from("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60", "hex"));
export const signer = await importJWK({ ...jwk, d: base64URL(seed) }, "Ed25519");
export const ownerJWK = { kty: "OKP", crv: "Ed25519", x: base64URL(Buffer.from("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "hex")) };
export const ownerSigner = await importJWK({ ...ownerJWK, d: base64URL(Buffer.from("4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb", "hex")) }, "Ed25519");
export const ownerToken = base64URL(new Uint8Array(32).fill(94));
export const token = base64URL(new Uint8Array(32).fill(93));
export const now = 1_800_000_000_000;
export const roomID = "qa", keyID = "a".repeat(32);
export const record = { roomID, keyID, deviceID: "qa-phone", role: "phone", tokenHash: await tokenHash(token),
  jwk, expiresAt: now + 3_600_000 };
export const ownerRecord = { ...record, deviceID: "qa-owner", role: "mac", tokenHash: await tokenHash(ownerToken), jwk: ownerJWK };
export const registry = JSON.stringify([record]);
export const context = (resource = "mailbox/mac", overrides = {}) => ({ roomID, keyID, resource, ...overrides });
export const url = (resource = "mailbox/mac") => `https://relay.example/v3/rooms/${roomID}/${resource}`;

export async function proof({ method = "POST", uri = url(), nonce, time = now, claims = {}, header = {}, key = signer } = {}) {
  const payload = { htm: method, htu: targetURI(uri), iat: Math.floor(time / 1000), jti: crypto.randomUUID(),
    ath: await tokenHash(token), ...(nonce === undefined ? {} : { nonce }), ...claims };
  for (const name of Object.keys(payload)) if (payload[name] === undefined) delete payload[name];
  return new SignJWT(payload).setProtectedHeader({ alg: "Ed25519", typ: "dpop+jwt", jwk, ...header }).sign(key);
}
export function request(signed, { method = "POST", uri = url(), accessToken = token, headers = {}, body } = {}) {
  return new Request(uri, { method, headers: { Authorization: `DPoP ${accessToken}`, DPoP: signed, ...headers },
    ...(body === undefined ? {} : { body }) });
}
export const keys = {
  nonce: (device = record.deviceID, room = roomID, epoch = keyID) => `device-auth:nonce:${room}:${epoch}:${device}`,
  revoked: (device = record.deviceID, room = roomID, epoch = keyID) => `device-auth:revoked:${room}:${epoch}:${device}`,
  replay: (id, device = record.deviceID, room = roomID, epoch = keyID) => `device-auth:replay:${room}:${epoch}:${device}:${id}`,
};
export const nonceRecord = (nonce, expiresAt = now + 120_000) => ({ version: 1, nonce, expiresAt });
export const nonce = base64URL(new Uint8Array(32).fill(23));

// Deterministic transactional fake, NOT a Durable Object runtime. It clones
// each attempt, serializes concurrent transactions and commits only on success.
export class MemoryJournal {
  constructor(persisted = new Map()) { this.persisted = persisted; this.tail = Promise.resolve(); this.transactions = 0; }
  failNext(operation = "commit") { this.failure = operation; }
  snapshot() { return structuredClone(this.persisted); }
  async transaction(callback) {
    const operation = this.tail.then(async () => {
      this.transactions++;
      const draft = structuredClone(this.persisted);
      const check = name => { if (this.failure === name) { this.failure = undefined; throw Error(`injected ${name}`); } };
      const transaction = {
        get: async key => { check("get"); return structuredClone(draft.get(key)); },
        put: async (key, value) => { check("put"); draft.set(key, structuredClone(value)); },
        delete: async key => { check("delete"); for (const value of Array.isArray(key) ? key : [key]) draft.delete(value); },
        list: async ({ prefix, limit }) => { check("list"); return new Map([...draft].filter(([key]) => key.startsWith(prefix)).sort(([a], [b]) => a.localeCompare(b)).slice(0, limit)); },
      };
      const result = await callback(transaction);
      check("commit");
      this.persisted.clear(); for (const [key, value] of draft) this.persisted.set(key, value);
      return result;
    });
    this.tail = operation.catch(() => {});
    return operation;
  }
}
