import { standardEmoji } from "./emoji";

export type JSONObject = { [key: string]: unknown };
export class GatewayError extends Error {
  constructor(public code: string, public status = 502, public retryAfter?: number) {
    super(code);
  }
}
export function object(value: unknown): JSONObject {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new GatewayError("invalid_response");
  return value as JSONObject;
}
export async function boundedJSON(body: ReadableStream<Uint8Array> | null, maxBytes: number): Promise<unknown> {
  if (!body) throw new GatewayError("empty_body", 400);
  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let count = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      count += chunk.value.byteLength;
      if (count > maxBytes) {
        await reader.cancel();
        throw new GatewayError("body_too_large", 413);
      }
      chunks.push(chunk.value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(count);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)); }
  catch { throw new GatewayError("invalid_json", 400); }
}
export async function slackAPI(token: string, method: string, data: JSONObject = {}, write = false): Promise<JSONObject> {
  // The destination is never supplied by a device, and redirects cannot leak
  // the user token to a third-party host. No credential or message logging.
  const url = new URL(`https://slack.com/api/${method}`);
  if (!write) for (const [key, value] of Object.entries(data)) url.searchParams.set(key, String(value));
  let response: Response;
  try {
    response = await fetch(url, {
      method: write ? "POST" : "GET", redirect: "manual",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json; charset=utf-8" },
      body: write ? JSON.stringify(data) : undefined,
      signal: AbortSignal.timeout(15_000),
    });
  } catch { throw new GatewayError(write ? "delivery_uncertain" : "slack_unavailable"); }
  if (response.status === 429) {
    await response.body?.cancel();
    const delay = Number(response.headers.get("Retry-After"));
    throw new GatewayError("rate_limited", 429, Number.isFinite(delay) && delay > 0 ? Math.ceil(delay) : 60);
  }
  if (!response.ok) {
    await response.body?.cancel();
    throw new GatewayError(write ? "delivery_uncertain" : "slack_unavailable");
  }
  let result: JSONObject;
  try { result = object(await boundedJSON(response.body, 512 * 1024)); }
  catch { throw new GatewayError(write ? "delivery_uncertain" : "invalid_response"); }
  if (result.ok !== true) {
    const code = typeof result.error === "string" && /^[a-z_]{1,80}$/.test(result.error) ? result.error : "invalid_response";
    if (write && ["internal_error", "fatal_error", "request_timeout", "invalid_response"].includes(code)) {
      throw new GatewayError("delivery_uncertain");
    }
    const authError = ["invalid_auth", "token_revoked", "token_expired", "not_authed", "account_inactive", "missing_scope"].includes(code);
    throw new GatewayError(code, authError ? 503 : 502);
  }
  return result;
}
export const validTimestamp = (s: unknown): s is string => typeof s === "string" && /^\d{10,12}\.\d{6}$/.test(s);
export function slackText(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
export function readableSlackText(text: string, blocks: unknown[]): string {
  // Slack retrieves standard emoji as colon aliases. Prefer Unicode from
  // rich_text and fall back to its documented standard catalogue. Never
  // fetch custom emoji URLs or execute interactive blocks.
  const emoji = new Map<string, string>();
  let budget = 512;
  function visit(value: unknown, depth: number) {
    if (--budget < 0 || depth > 6 || !value || typeof value !== "object" || Array.isArray(value)) return;
    const item = value as JSONObject;
    if (item.type === "emoji" && typeof item.name === "string" && typeof item.unicode === "string"
      && /^[a-z0-9_+:-]{1,100}$/.test(item.name) && /^[a-fA-F0-9]{1,6}(?:-[a-fA-F0-9]{1,6}){0,7}$/.test(item.unicode)) {
      const points = item.unicode.split("-").map(s => parseInt(s, 16));
      if (points.every(p => p >= 0x80 && p <= 0x10ffff && (p < 0xd800 || p > 0xdfff))) {
        emoji.set(`:${item.name}:`, String.fromCodePoint(...points));
      }
    }
    if (Array.isArray(item.elements)) for (const child of item.elements) visit(child, depth + 1);
  }
  for (const block of blocks) {
    if (block && typeof block === "object" && !Array.isArray(block) && (block as JSONObject).type === "rich_text") visit(block, 0);
  }
  let result = text;
  for (const [alias, unicode] of emoji) result = result.split(alias).join(unicode);
  return standardEmoji(result).replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
}
export async function digest(text: string): Promise<string> {
  const bytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, "0")).join("");
}
export async function authorized(request: Request, expected: string | undefined): Promise<boolean> {
  // Fixed-size hashing avoids token-length and prefix timing disclosure.
  const supplied = request.headers.get("Authorization")?.replace(/^Bearer /, "") || "";
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected || "")),
  ]);
  return crypto.subtle.timingSafeEqual(a, b) && !!expected && !!supplied;
}
