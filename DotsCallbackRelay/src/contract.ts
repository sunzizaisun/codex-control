import { z } from "zod";
import { EventError } from "./errors.ts";

export const envelopeSchema = z.object({
  url: z.string().max(2048),
  body: z.string().refine(s => new TextEncoder().encode(s).byteLength <= 262144 &&
    [...s].every(c => { const p = c.codePointAt(0)!; return p < 0xd800 || p > 0xdfff; })),
  issuedAt: z.number().int().safe(),
  headers: z.object({
    "Content-Type": z.literal("application/json"),
    "webhook-id": z.string().regex(/^[A-Za-z0-9_-]{1,128}$/),
    "webhook-timestamp": z.string().regex(/^\d{1,12}$/),
    "webhook-signature": z.string().max(512).regex(/^v1,[A-Za-z0-9+/]+={0,2}(?: v1,[A-Za-z0-9+/]+={0,2})?$/),
    "X-MCP-Subscription-Id": z.string().regex(/^[A-Za-z0-9_-]{1,128}$/),
  }).strict(),
}).strict();
export const responseSchema = z.object({ status: z.number().int().min(200).max(599),
  body: z.string().refine(s => new TextEncoder().encode(s).byteLength <= 8192) }).strict();
export type RelayEnvelope = z.infer<typeof envelopeSchema>;

export async function relayKey(secret: string) {
  if (!/^[a-f0-9]{64}$/.test(secret)) throw new EventError("relay_not_configured", -32603, 503, "callback_relay");
  // This key is dedicated to signed callback forwarding, never a GPT login,
  // root relay key, webhook signing secret, or inference API key.
  return await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}
export async function signEnvelope(secret: string, bytes: Uint8Array) {
  const signature = await crypto.subtle.sign("HMAC", await relayKey(secret), new Uint8Array(bytes));
  return Array.from(new Uint8Array(signature), n => n.toString(16).padStart(2, "0")).join("");
}
export async function verifyEnvelope(secret: string, bytes: Uint8Array, signature: string) {
  if (!/^[a-f0-9]{64}$/.test(signature)) return false;
  const decoded = Uint8Array.from(signature.match(/../g)!, s => parseInt(s, 16));
  return await crypto.subtle.verify("HMAC", await relayKey(secret), decoded, new Uint8Array(bytes));
}
