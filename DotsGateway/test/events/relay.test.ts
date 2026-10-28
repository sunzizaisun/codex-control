import { describe, it, expect } from "vitest";
import { relayPost } from "../../../DotsCallbackRelay/src/client";
import { relayHandler } from "../../../DotsCallbackRelay/src/handler";
import type { DeliveryIO, DeliverySocket } from "../../../DotsCallbackRelay/src/transport";
import { signedLivePost, verifyLiveCallback } from "../../src/events/delivery";
import { Webhook } from "standardwebhooks";
import { http } from "msw";
import { network } from "../network";
const config = { url: "https://callbacks.wearable.deno.net/relay", key: "a".repeat(64) };
const headers = { "Content-Type": "application/json", "webhook-id": "event_123", "webhook-timestamp": "1790000000",
  "webhook-signature": "v1,YWJjZA==", "X-MCP-Subscription-Id": "sub_123" };
describe("callback relay client in actual Workers runtime (isolated mock callback)", () => {
  it("authenticates exact bytes across client and server and keeps signing/account keys absent", async () => {
    const written: Uint8Array[] = [], body = '{"text":"松果-742，🙂"}';
    const socket: DeliverySocket = { opened: Promise.resolve(), closed: Promise.resolve(), close() { return Promise.resolve(); }, startTls() { return socket; },
      readable: new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")); c.close(); } }),
      writable: new WritableStream({ write(value) { written.push(value); } }) };
    const io: DeliveryIO = { resolve() { return Promise.resolve(["104.16.0.1"]); }, connect() { return socket; } };
    const handler = relayHandler(config.key, io);
    const response = await relayPost(config, "https://callback.example/events", body, headers, async (url, init) => {
      expect(url).toBe(config.url); expect(init.redirect).toBe("manual");
      expect(Object.keys(JSON.parse(String(init.body))).sort()).toEqual(["body", "headers", "issuedAt", "url"]);
      return await handler(new Request(url, init));
    });
    expect(response.status).toBe(200); expect(await response.text()).toBe("{}");
    expect(new TextDecoder().decode(written[1])).toBe(body);
  });
  it("does not follow a relay redirect or use an unpinned callback fallback", async () => {
    let count = 0;
    await expect(relayPost(config, "https://callback.example/x", "{}", headers, async () => {
      count++; return new Response(null, { status: 302, headers: { Location: "https://elsewhere.example" } });
    })).rejects.toMatchObject({ code: "callback_relay_unavailable" }); expect(count).toBe(1);
  });
  it("rejects a changed body signature before callback I/O", async () => {
    const io: DeliveryIO = { async resolve() { throw new Error("must-not-resolve"); }, connect() { throw new Error("must-not-connect"); } };
    const response = await relayHandler(config.key, io)(new Request(config.url, { method: "POST", body: "{}",
      headers: { "Content-Type": "application/json", "X-Relay-Signature": "b".repeat(64) } }));
    expect(response.status).toBe(401); expect(await response.json()).toEqual({ error: "unauthorized" });
  });
  it("routes production signed delivery through the configured relay without sharing the signing key", async () => {
    const secret = `whsec_${btoa("s".repeat(32))}`;
    const sub = { id: "sub_123", url: "https://callback.example/events", secret, expiresAt: Date.now() + 60000, revision: "test" };
    const payload = { eventId: "event_123", text: "中文跟进收发一致，测试结束🙂" };
    let count = 0;
    network.use(http.post(config.url, async ({ request }) => {
      count++;
      const raw = await request.text();
      expect(raw).not.toContain(secret); expect(raw).not.toContain(config.key);
      const envelope = JSON.parse(raw);
      expect(envelope.url).toBe(sub.url);
      expect(new Webhook(secret).verify(envelope.body, envelope.headers)).toEqual(payload);
      expect(envelope.headers["X-MCP-Subscription-Id"]).toBe(sub.id);
      expect(request.headers.get("X-Relay-Signature")).toMatch(/^[a-f0-9]{64}$/);
      return Response.json({ status: 202, body: "" });
    }));
    expect((await signedLivePost(sub, payload.eventId, payload, config)).status).toBe(202);
    expect(count).toBe(1);
  });
  it("verifies the actual challenge response over the same relay route", async () => {
    const sub = { id: "sub_123", url: "https://callback.example/events", secret: `whsec_${btoa("s".repeat(32))}`, expiresAt: Date.now() + 60000, revision: "test" };
    let count = 0;
    network.use(http.post(config.url, async ({ request }) => {
      count++;
      const envelope = await request.json() as { body: string; headers: Record<string, string> };
      const data = new Webhook(sub.secret).verify(envelope.body, envelope.headers) as { type: string; challenge: string };
      expect(data.type).toBe("verification");
      return Response.json({ status: 200, body: JSON.stringify({ challenge: data.challenge }) });
    }));
    await verifyLiveCallback(sub, config); expect(count).toBe(1);
  });
  it("does not fall back to another transport after an unavailable production relay", async () => {
    const sub = { id: "sub_123", url: "https://callback.example/events", secret: `whsec_${btoa("s".repeat(32))}`, expiresAt: Date.now() + 60000, revision: "test" };
    let count = 0;
    network.use(http.post(config.url, () => { count++; return Response.json({ error: "timeout" }, { status: 503 }); }));
    await expect(signedLivePost(sub, "event_123", {}, config)).rejects.toMatchObject({ code: "timeout", phase: "callback_relay" });
    expect(count).toBe(1);
  });
});
