import { Webhook } from "standardwebhooks";
import { z } from "zod";
import { boundedJSON, digest } from "../slack";
import type { OwnerAuthorization } from "./auth-core";
import { EventError } from "../../../DotsCallbackRelay/src/errors";
export { EventError } from "../../../DotsCallbackRelay/src/errors";

export const eventName = "wearable.message.created";
export const inboxArgs = z.object({ inbox: z.literal("wearable") }).strict();
const delivery = z.object({ mode: z.literal("webhook"), url: z.string().max(2048), secret: z.string().max(128) }).strict();
export const subscribeSchema = z.object({ name: z.literal(eventName), arguments: inboxArgs, delivery,
  cursor: z.null().optional(), ttlMs: z.number().int().positive().max(30 * 86400_000).nullable().optional(),
}).strict();
export const unsubscribeSchema = z.object({ name: z.literal(eventName), arguments: inboxArgs,
  delivery: delivery.omit({ secret: true }),
}).strict();
export function boundedText(max: number) {
  return z.string().refine(s => {
    const points = [...s];
    // Lone UTF-16 surrogates change to replacement characters at transport or
    // storage boundaries. Reject them instead of silently changing user text.
    return s.trim().length > 0 && points.length <= max && points.every(point => {
      const code = point.codePointAt(0)!;
      return code < 0xd800 || code > 0xdfff;
    });
  });
}
export const commandSchema = z.object({ id: z.uuid(), thread: z.uuid().optional(), shared: z.boolean().optional(),
  text: boundedText(4000),
  createdAt: z.number().int().safe(),
}).strict();
export const replySchema = z.object({ message_id: z.uuid(),
  text: boundedText(16000),
}).strict();
export const threadReadSchema = z.object({
  thread_id: z.uuid(),
  // Optional for older clients. Explicit recovery can select one known input
  // without exposing or marking any neighbouring message as read.
  message_id: z.uuid().optional(),
  limit: z.number().int().min(1).max(30).optional(),
}).strict();
export type Subscribe = z.infer<typeof subscribeSchema>;
export type Command = z.infer<typeof commandSchema>;
export type Reply = z.infer<typeof replySchema>;
export type Subscription = { id: string; url: string; secret: string; oldSecret?: string; rotateBefore?: number; expiresAt: number; revision: string; authorization?: OwnerAuthorization };
export type MessageEvent = { eventId: string; name: typeof eventName; timestamp: string;
  data: { inbox: "wearable"; message_id: string; thread_id: string; text: string; request_kind?: "history_sync" }; cursor: null };

export function parse<T>(schema: z.ZodType<T>, value: unknown): T {
  const result = schema.safeParse(value);
  if (!result.success) throw new EventError("invalid_params");
  return result.data;
}
export async function sameSecret(a: string, b: string) {
  const e = new TextEncoder();
  const [x, y] = await Promise.all([crypto.subtle.digest("SHA-256", e.encode(a)), crypto.subtle.digest("SHA-256", e.encode(b))]);
  return crypto.subtle.timingSafeEqual(x, y);
}
export function validateSigningSecret(secret: string) {
  if (!/^whsec_[A-Za-z0-9+/]+={0,2}$/.test(secret)) throw new EventError("invalid_signing_secret");
  try {
    const value = atob(secret.slice(6));
    if (value.length < 24 || value.length > 64 || btoa(value) !== secret.slice(6)) throw new Error();
  } catch { throw new EventError("invalid_signing_secret"); }
}
export async function subscriptionID(owner: string, url: string) {
  // Arguments contain one fixed filter; explicit canonical ordering prevents
  // subscription duplicates due to JSON property order.
  return `sub_${await digest(JSON.stringify([owner, url, eventName, { inbox: "wearable" }]))}`;
}
export const definition = {
  name: eventName,
  description: "A companion message, or an explicit history-sync control request (request_kind=history_sync). Sync requests are not chat messages and must not be answered or mirrored into ChatGPT.",
  delivery: ["webhook"], inputSchema: z.toJSONSchema(inboxArgs),
  payloadSchema: z.toJSONSchema(z.object({ inbox: z.literal("wearable"), message_id: z.uuid(), thread_id: z.uuid(), text: z.string(), request_kind: z.literal("history_sync").optional() }).strict()),
};

// This is deliberately a FIXTURE transport, not a production SSRF guard.
// Real callback delivery stays disabled until an OAuth connection and a
// connection-time DNS/IP-pinned transport have been reviewed and authorized.
// .invalid is reserved and cannot be a real OpenAI or third-party callback.
function fixtureDestination(raw: string) {
  let url: URL;
  try { url = new URL(raw); } catch { throw new EventError("callback_blocked", -32015); }
  if (url.protocol !== "https:" || url.hostname !== "mcp-callback.invalid" || url.port
    || url.username || url.password || url.hash || !url.pathname.startsWith("/events/")) {
    throw new EventError("callback_blocked", -32015);
  }
  return url.href;
}
export async function signedPost(sub: Subscription, id: string, payload: unknown,
  post: (url: string, body: string, headers: Record<string, string>) => Promise<Response>): Promise<Response> {
  const body = JSON.stringify(payload);
  if (new TextEncoder().encode(body).byteLength > 262144) throw new EventError("payload_too_large", -32602, 413);
  const at = new Date();
  const signatures = [new Webhook(sub.secret).sign(id, at, body)];
  if (sub.oldSecret && (sub.rotateBefore || 0) > Date.now()) signatures.push(new Webhook(sub.oldSecret).sign(id, at, body));
  try {
    return await post(sub.url, body, { "Content-Type": "application/json", "webhook-id": id,
        "webhook-timestamp": String(Math.floor(at.getTime() / 1000)), "webhook-signature": signatures.join(" "),
        "X-MCP-Subscription-Id": sub.id });
  } catch (error) { if (error instanceof EventError) throw error; throw new EventError("timeout", -32015, 503); }
}
export const signedFixturePost = (sub: Subscription, id: string, payload: unknown) => signedPost(sub, id, payload,
  (url, body, headers) => fetch(fixtureDestination(url), { method: "POST", redirect: "manual", signal: AbortSignal.timeout(10_000), headers, body }));
export async function verifyCallback(sub: Subscription, post = signedFixturePost) {
  validateSigningSecret(sub.secret);
  const challenge = crypto.randomUUID();
  const response = await post(sub, `verification_${crypto.randomUUID()}`, { type: "verification", challenge });
  if (!response.ok) { await response.body?.cancel(); throw new EventError("challenge_failed", -32015); }
  let value: unknown;
  try { value = await boundedJSON(response.body, 4096); } catch { throw new EventError("challenge_failed", -32015); }
  const result = z.object({ challenge: z.string().max(100) }).strict().safeParse(value);
  if (!result.success || !await sameSecret(result.data.challenge, challenge)) throw new EventError("challenge_failed", -32015);
}
export const verifyFixtureCallback = (sub: Subscription) => verifyCallback(sub);
