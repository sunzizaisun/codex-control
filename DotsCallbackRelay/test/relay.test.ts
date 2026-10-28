import { strict as assert } from "node:assert";
import { relayHandler } from "../src/handler.ts";
import { signEnvelope, type RelayEnvelope } from "../src/contract.ts";
import { pinnedPost, type DeliveryIO, type DeliverySocket } from "../src/transport.ts";

const secret = "a".repeat(64);
function fixture(response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", addresses = ["104.16.0.1"]) {
  const written: Uint8Array[] = [], hosts: string[] = [], tlsHosts: string[] = [];
  let closed = 0, resolved = 0;
  const socket: DeliverySocket = {
    opened: Promise.resolve(), closed: Promise.resolve(),
    readable: new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(response)); c.close(); } }),
    writable: new WritableStream({ write(bytes) { written.push(bytes); } }),
    startTls(options) { tlsHosts.push(options.expectedServerHostname); return socket; },
    close() { closed++; return Promise.resolve(); },
  };
  const io: DeliveryIO = { resolve() { resolved++; return Promise.resolve(addresses); },
    connect(address) { hosts.push(address.hostname); return socket; } };
  return { io, written, hosts, tlsHosts, socket, stats: () => ({ closed, resolved }) };
}
function envelope(overrides: Partial<RelayEnvelope> = {}): RelayEnvelope {
  return { url: "https://callback.example/events/one", issuedAt: Date.now(), body: '{"text":"松果-742，测试结束🙂"}',
    headers: { "Content-Type": "application/json", "webhook-id": "event_123", "webhook-timestamp": String(Math.floor(Date.now() / 1000)),
      "webhook-signature": "v1,YWJjZA==", "X-MCP-Subscription-Id": "sub_123" }, ...overrides };
}
async function request(value: unknown, options: { key?: string; path?: string; method?: string; origin?: string; signature?: string } = {}) {
  const body = JSON.stringify(value), bytes = new TextEncoder().encode(body);
  return new Request(`https://relay.example${options.path || "/relay"}`, { method: options.method || "POST", body,
    headers: { "Content-Type": "application/json", "X-Relay-Signature": options.signature ?? await signEnvelope(options.key || secret, bytes),
      ...(options.origin ? { Origin: options.origin } : {}) } });
}
Deno.test("authenticated relay pins Cloudflare public IP and preserves exact Unicode", async () => {
  const f = fixture(), value = envelope(), handler = relayHandler(secret, f.io);
  const response = await handler(await request(value));
  assert.equal(response.status, 200); assert.deepEqual(await response.json(), { status: 200, body: "{}" });
  assert.deepEqual(f.hosts, ["104.16.0.1"]); assert.deepEqual(f.tlsHosts, ["callback.example"]);
  assert.equal(new TextDecoder().decode(f.written[1]), value.body);
  assert.match(new TextDecoder().decode(f.written[0]), new RegExp(`Content-Length: ${new TextEncoder().encode(value.body).byteLength}`));
  assert.deepEqual(f.stats(), { closed: 1, resolved: 1 });
});
for (const address of ["127.0.0.1", "10.0.0.1", "169.254.169.254", "100.64.0.1", "::1", "fc00::1", "fe80::1", "::ffff:8.8.8.8", "2001:db8::1"]) {
  Deno.test(`blocks complete DNS set containing ${address}`, async () => {
    const f = fixture(undefined, ["104.16.0.1", address]);
    const response = await relayHandler(secret, f.io)(await request(envelope()));
    assert.equal(response.status, 400); assert.equal((await response.json()).error, "callback_blocked"); assert.deepEqual(f.hosts, []);
  });
}
for (const url of ["http://callback.example/x", "https://u:p@callback.example/x", "https://callback.example:8443/x", "https://localhost/x", "https://callback.local/x", "https://callback.example/x#secret"]) {
  Deno.test(`blocks invalid callback URL ${url}`, async () => {
    const f = fixture(); const response = await relayHandler(secret, f.io)(await request(envelope({ url })));
    assert.equal(response.status, 400); await response.body?.cancel(); assert.deepEqual(f.hosts, []);
  });
}
for (const options of [{ key: "b".repeat(64) }, { signature: "bad" }, { origin: "https://anywhere.example" }]) {
  Deno.test(`rejects unauthorized request ${JSON.stringify(options).slice(0, 30)}`, async () => {
    const f = fixture(); const response = await relayHandler(secret, f.io)(await request(envelope(), options));
    assert.ok([401, 403].includes(response.status)); await response.body?.cancel(); assert.equal(f.stats().resolved, 0);
  });
}
for (const delta of [-31000, 31000]) {
  Deno.test(`rejects expired or future auth envelope ${delta}`, async () => {
    const f = fixture(); const response = await relayHandler(secret, f.io)(await request(envelope({ issuedAt: Date.now() + delta })));
    assert.equal(response.status, 401); await response.body?.cancel(); assert.equal(f.stats().resolved, 0);
  });
}
for (const extra of [{ secret: "must-not-send" }, { OAuthToken: "must-not-send" }]) {
  Deno.test(`rejects extra credential field ${Object.keys(extra)[0]}`, async () => {
    const f = fixture(); const response = await relayHandler(secret, f.io)(await request({ ...envelope(), ...extra }));
    assert.equal(response.status, 400); await response.body?.cancel(); assert.equal(f.stats().resolved, 0);
  });
}
Deno.test("rejects header injection and reserved header overrides", async () => {
  for (const headers of [{ ...envelope().headers, "webhook-id": "a\r\nInjected: x" }, { ...envelope().headers, Host: "evil.example" }, { ...envelope().headers, Authorization: "must-not-send" }]) {
    const f = fixture(); const response = await relayHandler(secret, f.io)(await request({ ...envelope(), headers }));
    assert.equal(response.status, 400); await response.body?.cancel(); assert.equal(f.stats().resolved, 0);
  }
});
for (const status of [302, 410, 413, 429, 500]) {
  Deno.test(`preserves callback ${status}, without redirect or false acknowledgement`, async () => {
    const f = fixture(`HTTP/1.1 ${status} Result\r\nLocation: http://169.254.169.254/\r\nContent-Length: 0\r\n\r\n`);
    const response = await relayHandler(secret, f.io)(await request(envelope()));
    assert.equal(response.status, 200); assert.deepEqual(await response.json(), { status, body: "" }); assert.equal(f.hosts.length, 1);
  });
}
Deno.test("TLS verification failure never sends data or falls back to fetch", async () => {
  const f = fixture(); f.socket.startTls = () => { throw new Error("private-tls-detail"); };
  const response = await relayHandler(secret, f.io)(await request(envelope()));
  assert.equal(response.status, 503); assert.deepEqual(await response.json(), { error: "callback_connection_failed", phase: "callback_tls" }); assert.deepEqual(f.written, []);
});
Deno.test("health check contains no credentials or destination", async () => {
  const f = fixture(); const response = await relayHandler(secret, f.io)(new Request("https://relay.example/health"));
  assert.deepEqual(await response.json(), { ok: true, mode: "signed-callback-only" }); assert.equal(f.stats().resolved, 0);
});
Deno.test("oversized response is rejected and socket closed", async () => {
  const f = fixture(`HTTP/1.1 200 OK\r\nContent-Length: 8193\r\n\r\n${"x".repeat(8193)}`);
  await assert.rejects(pinnedPost("https://callback.example/x", "{}", {}, f.io)); assert.equal(f.stats().closed, 1);
});
