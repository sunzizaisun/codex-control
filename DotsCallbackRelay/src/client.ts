import { boundedJSON } from "./body.ts";
import { envelopeSchema, responseSchema, signEnvelope } from "./contract.ts";
import { EventError } from "./errors.ts";
import { callbackURL } from "./transport.ts";

export type RelayConfiguration = { url: string; key: string };
const errorCodes = new Set(["callback_blocked", "callback_dns_failed", "callback_connection_failed", "callback_response_too_large", "callback_invalid_response", "timeout", "invalid_envelope", "expired_envelope", "relay_not_configured", "unauthorized"]);
function endpoint(raw: string) {
  let url: URL;
  try { url = new URL(raw); } catch { throw new EventError("relay_not_configured", -32603, 503, "callback_relay"); }
  if (url.protocol !== "https:" || !/^[a-z0-9-]+\.[a-z0-9-]+\.deno\.net$/.test(url.hostname)
    || url.username || url.password || url.port || url.search || url.hash || url.pathname !== "/relay") {
    throw new EventError("relay_not_configured", -32603, 503, "callback_relay");
  }
  return url.href;
}
// Only the configured, authorized relay receives this request. It does the
// connection-time DNS/IP validation; there is NO fallback to a callback fetch.
export async function relayPost(config: RelayConfiguration, raw: string, body: string, headers: Record<string, string>,
  request: (url: string, init: RequestInit) => Promise<Response> = fetch): Promise<Response> {
  const destination = endpoint(config.url);
  callbackURL(raw);
  const input = envelopeSchema.safeParse({ url: raw, body, headers, issuedAt: Date.now() });
  if (!input.success) throw new EventError("invalid_envelope");
  const envelope = JSON.stringify(input.data), bytes = new TextEncoder().encode(envelope);
  let response: Response;
  try {
    response = await request(destination, { method: "POST", body: envelope,
      headers: { "Content-Type": "application/json", "X-Relay-Signature": await signEnvelope(config.key, bytes) },
      redirect: "manual", signal: AbortSignal.timeout(35_000) });
  } catch (error) {
    if (error instanceof EventError) throw error;
    throw new EventError("callback_relay_unavailable", -32015, 503, "callback_relay");
  }
  let value: unknown;
  try { value = await boundedJSON(response.body, 64 * 1024); }
  catch { throw new EventError("callback_relay_unavailable", -32015, 503, "callback_relay"); }
  if (!response.ok) {
    // No arbitrary relay error strings or exception details enter diagnostics.
    const code = value && typeof value === "object" && "error" in value && typeof value.error === "string" && errorCodes.has(value.error)
      ? value.error : "callback_relay_unavailable";
    throw new EventError(code, -32015, response.status >= 500 ? 503 : 400, "callback_relay");
  }
  const result = responseSchema.safeParse(value);
  if (!result.success) throw new EventError("callback_relay_unavailable", -32015, 503, "callback_relay");
  return new Response([204, 205, 304].includes(result.data.status) ? null : result.data.body, { status: result.data.status });
}
