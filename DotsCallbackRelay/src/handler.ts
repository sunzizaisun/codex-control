import { boundedBytes } from "./body.ts";
import { envelopeSchema, verifyEnvelope } from "./contract.ts";
import { EventError } from "./errors.ts";
import { pinnedPost, type DeliveryIO } from "./transport.ts";

const headers = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
const json = (value: unknown, status = 200) => Response.json(value, { status, headers });
export function relayHandler(secret: string, io: DeliveryIO) {
  return async (request: Request): Promise<Response> => {
    const url = new URL(request.url);
    if (url.pathname === "/health" && request.method === "GET") return json({ ok: /^[a-f0-9]{64}$/.test(secret), mode: "signed-callback-only" });
    if (url.pathname !== "/relay") return json({ error: "not_found" }, 404);
    if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
    // Only server-to-server traffic. No browser CORS and no public proxy.
    if (request.headers.has("Origin")) return json({ error: "invalid_origin" }, 403);
    if (request.headers.get("Content-Type")?.split(";")[0] !== "application/json") return json({ error: "unsupported_media_type" }, 415);
    if (!/^[a-f0-9]{64}$/.test(request.headers.get("X-Relay-Signature") || "")) return json({ error: "unauthorized" }, 401);
    let timer: ReturnType<typeof setTimeout> | undefined;
    const controller = new AbortController();
    try {
      const bytes = await Promise.race([boundedBytes(request.body, 600 * 1024, controller.signal), new Promise<never>((_, reject) => {
        timer = setTimeout(() => { controller.abort(); reject(new EventError("timeout", -32015, 408)); }, 5000);
      })]);
      clearTimeout(timer);
      if (!await verifyEnvelope(secret, bytes, request.headers.get("X-Relay-Signature")!)) return json({ error: "unauthorized" }, 401);
      let raw: unknown;
      try { raw = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)); } catch { throw new EventError("invalid_json"); }
      const input = envelopeSchema.safeParse(raw);
      if (!input.success) throw new EventError("invalid_envelope");
      if (Math.abs(Date.now() - input.data.issuedAt) > 30_000) throw new EventError("expired_envelope", -32000, 401);
      const response = await pinnedPost(input.data.url, input.data.body, input.data.headers, io);
      // Status is returned as data: a callback 302/410/413 must never become
      // success, trigger a redirect, or lose its durable retry policy.
      return json({ status: response.status, body: await response.text() }); // Transport bounds body to 8 KiB.
    } catch (error) {
      const e = error instanceof EventError ? error : new EventError("callback_connection_failed", -32015, 503);
      return json({ error: e.code, ...(e.phase ? { phase: e.phase } : {}), ...(e.dnsReason ? { dnsReason: e.dnsReason } : {}) }, e.status);
    } finally { clearTimeout(timer); }
  };
}
