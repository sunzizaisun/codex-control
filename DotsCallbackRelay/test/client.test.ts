import { strict as assert } from "node:assert";
import { relayPost } from "../src/client.ts";
import { relayHandler } from "../src/handler.ts";
import type { DeliveryIO, DeliverySocket } from "../src/transport.ts";
const config = { url: "https://callbacks.wearable.deno.net/relay", key: "a".repeat(64) };
const headers = { "Content-Type": "application/json", "webhook-id": "event_123", "webhook-timestamp": "1790000000",
  "webhook-signature": "v1,YWJjZA==", "X-MCP-Subscription-Id": "sub_123" };

Deno.test("Worker client to relay to mock callback preserves signed body/header bytes", async () => {
  const written: Uint8Array[] = [], body = '{"text":"中文跟进收发一致，测试结束🙂"}';
  const socket: DeliverySocket = { opened: Promise.resolve(), closed: Promise.resolve(), close() { return Promise.resolve(); }, startTls() { return socket; },
    readable: new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")); c.close(); } }),
    writable: new WritableStream({ write(value) { written.push(value); } }) };
  const io: DeliveryIO = { resolve() { return Promise.resolve(["104.16.0.1"]); }, connect() { return socket; } };
  const handler = relayHandler(config.key, io);
  const response = await relayPost(config, "https://callback.example/events", body, headers, async (url, init) => {
    assert.equal(url, config.url); assert.equal(init.redirect, "manual");
    // Exact-key assertion proves account/webhook secrets cannot be serialized.
    assert.deepEqual(Object.keys(JSON.parse(String(init.body))).sort(), ["body", "headers", "issuedAt", "url"]);
    return await handler(new Request(url, init));
  });
  assert.equal(response.status, 200); assert.equal(await response.text(), "{}");
  assert.equal(new TextDecoder().decode(written[1]), body);
  const wire = new TextDecoder().decode(written[0]);
  for (const [key, value] of Object.entries(headers)) assert.ok(wire.includes(`${key}: ${value}\r\n`));
  assert.ok(!wire.includes("X-Relay-Signature"));
});
for (const url of ["https://evil.example/relay", "http://callbacks.wearable.deno.net/relay", "https://callbacks.wearable.deno.net/relay?key=x", "https://callbacks.wearable.deno.net/elsewhere", "https://user:pass@callbacks.wearable.deno.net/relay"]) {
  Deno.test(`client refuses unconfigured relay ${url}`, async () => {
    let calls = 0;
    await assert.rejects(relayPost({ ...config, url }, "https://callback.example/x", "{}", headers, () => { calls++; return Promise.resolve(new Response()); }));
    assert.equal(calls, 0);
  });
}
for (const status of [302, 410, 413, 429, 500]) {
  Deno.test(`client preserves callback status ${status}`, async () => {
    const response = await relayPost(config, "https://callback.example/x", "{}", headers, () => Promise.resolve(Response.json({ status, body: "" })));
    assert.equal(response.status, status); await response.body?.cancel();
  });
}
Deno.test("client never follows relay redirect or falls back to callback", async () => {
  let calls = 0;
  await assert.rejects(relayPost(config, "https://callback.example/x", "{}", headers, () => {
    calls++; return Promise.resolve(new Response(null, { status: 302, headers: { Location: "https://elsewhere.example" } }));
  })); assert.equal(calls, 1);
});
Deno.test("client sanitizes unexpected relay error data", async () => {
  await assert.rejects(relayPost(config, "https://callback.example/x", "{}", headers, () => Promise.resolve(Response.json({ error: "private-credential-detail" }, { status: 500 }))),
    { message: "callback_relay_unavailable" });
});
Deno.test("client rejects oversized relay responses", async () => {
  await assert.rejects(relayPost(config, "https://callback.example/x", "{}", headers, () => Promise.resolve(new Response("x".repeat(65537)))));
});
