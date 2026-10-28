import { createMcpHandler } from "@modelcontextprotocol/server";
import { AuthorizationError, insufficientScope, OAuthResourceServer, type AuthRequest } from "@cloudflare/workers-oauth-provider";
import { authorized, boundedJSON, digest, GatewayError } from "../slack";
import { authorizationServer, chatGPTClient, chatGPTRedirect, grantIsActive, issuer, resource, scopes } from "./auth-core";
import { DotEventInbox, type EventResult } from "./inbox";
import { commandSchema, EventError } from "./protocol";
import { serverFor } from "./preview";
import { resolveCallbackAddresses } from "./dns";
import { publicAddress } from "./delivery";
import { durableReadQuotaFailure } from "./quota-error";
import { eventResponse as response } from "./http-result";
// Separate from the deployed Slack gateway and the localhost-only fixture.
export { DotEventInbox } from "./inbox";

type OwnerProps = { owner: string };
const noStore = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
function json(data: unknown, status = 200) { return Response.json(data, { status, headers: noStore }); }
function requireResult(result: EventResult) {
  if (!result.ok) throw new EventError(result.error, result.rpcCode, result.status);
}
function checkRequest(auth: AuthRequest) {
  if (auth.clientId !== chatGPTClient || auth.redirectUri !== chatGPTRedirect || auth.resource !== resource
    || !auth.scope.includes(scopes[0]) || auth.scope.some(scope => ![...scopes, "offline_access"].includes(scope))
    || auth.codeChallengeMethod !== "S256" || !auth.codeChallenge) throw new EventError("unsupported_authorization_request", -32000, 400);
}
function escape(raw: string) { return raw.replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]!); }
function page(body: string, headers: Headers, chinese = false, status = 200) {
  const safeHeaders = new Headers(headers);
  const nonce = btoa(crypto.randomUUID());
  Object.entries(noStore).forEach(([key, value]) => safeHeaders.set(key, value));
  safeHeaders.set("Content-Type", "text/html; charset=utf-8");
  safeHeaders.set("Referrer-Policy", "no-referrer");
  safeHeaders.set("Content-Security-Policy", `default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}'; connect-src 'self'; form-action 'self' ${chatGPTRedirect}; frame-ancestors 'none'; base-uri 'none'`);
  // Explicit, same-origin form submission also reports errors in place. Never
  // bypass the browser cookie or the owner confirmation in the POST handler.
  const script = `document.querySelector('form').addEventListener('submit',async e=>{e.preventDefault();const f=e.currentTarget,b=Array.from(f.querySelectorAll('button')),s=document.getElementById('status'),d=new URLSearchParams(new FormData(f));d.set('decision',e.submitter?.value||'allow');b.forEach(x=>x.disabled=true);s.textContent=${JSON.stringify(chinese ? "正在连接…" : "Connecting…")};try{const r=await fetch('/authorize',{method:'POST',body:d,credentials:'same-origin',redirect:'error',headers:{Accept:'application/json'}}),v=await r.json();if(!r.ok)throw Error(v.error);const u=new URL(v.redirect);if(u.origin!=='https://chatgpt.com'||u.pathname!=='/connector_platform_oauth_redirect')throw Error('invalid_redirect');location.assign(u.href)}catch(err){s.textContent=${JSON.stringify(chinese ? "连接未完成。请让 Mac 确认本页编号后再试；如果页面已过期，请重新连接。" : "Connection did not complete. Confirm this page's ID on your Mac, then retry. If the page expired, reconnect.")};b.forEach(x=>x.disabled=false)}});`;
  return new Response(`<!doctype html><html lang="${chinese ? "zh" : "en"}"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Codex Control Dot Inbox</title><style>body{font:16px system-ui;background:#f5f5f7;color:#1d1d1f;margin:0;padding:32px 16px}main{max-width:480px;margin:5vh auto;background:white;border-radius:24px;padding:32px;box-shadow:0 8px 32px #0001}h1{font-size:25px;line-height:1.2}p{line-height:1.5}code{font-size:12px;overflow-wrap:anywhere;display:block;padding:12px;background:#f5f5f7;border-radius:10px}button{font:inherit;border:0;border-radius:12px;padding:12px 22px;cursor:pointer;background:#e8e8ed;color:#1d1d1f}button[value="allow"]{background:#007aff;color:white}button:disabled{opacity:.5}form{display:flex;gap:12px;margin-top:24px}small{color:#6e6e73}#status{font-size:14px;color:#6e6e73}</style><main>${body}<p id="status" role="status" aria-live="polite"></p></main><script nonce="${nonce}">${script}</script></html>`, { status, headers: safeHeaders });
}
function authorizationResponse(request: Request, headers: Headers, redirect: string) {
  if (request.headers.get("Accept")?.split(",").includes("application/json")) {
    const jsonHeaders = new Headers(headers);
    jsonHeaders.set("Content-Type", "application/json"); jsonHeaders.delete("Location");
    Object.entries(noStore).forEach(([key, value]) => jsonHeaders.set(key, value));
    return new Response(JSON.stringify({ redirect }), { headers: jsonHeaders });
  }
  headers.set("Location", redirect);
  return new Response(null, { status: 303, headers });
}
async function boundedForm(request: Request) {
  if (request.headers.get("Content-Type")?.split(";")[0] !== "application/x-www-form-urlencoded") throw new EventError("unsupported_media_type", -32602, 415);
  const reader = request.body?.getReader(); if (!reader) throw new EventError("invalid_form");
  const chunks: Uint8Array[] = []; let count = 0;
  try {
    for (;;) {
      const part = await reader.read(); if (part.done) break;
      count += part.value.byteLength;
      if (count > 16_384) { await reader.cancel(); throw new EventError("payload_too_large", -32602, 413); }
      chunks.push(part.value);
    }
  } finally { reader.releaseLock(); }
  const bytes = new Uint8Array(count); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  const form = new URLSearchParams(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  if ([...form.keys()].some(key => !["handle", "intent", "decision"].includes(key))
    || ["handle", "intent", "decision"].some(key => form.getAll(key).length !== 1)) throw new EventError("invalid_form");
  return { handle: form.get("handle")!, intent: form.get("intent")!, decision: form.get("decision")! };
}
async function authorize(request: Request, env: DotEventsEnv) {
  const api = authorizationServer.getOAuthApi(env), inbox = env.EVENT_INBOXES.getByName(env.EVENTS_OWNER);
  if (request.method === "GET") {
    const auth = await api.parseAuthRequest(request); checkRequest(auth);
    const description = await api.describeConsent(auth), consent = await api.beginConsent(auth);
    const intent = crypto.randomUUID();
    requireResult(await inbox.execute({ kind: "owner_begin", input: { id: intent, hash: await digest(consent.handle) } }));
    const chinese = /^zh\b/i.test(request.headers.get("Accept-Language") ?? "");
    const title = chinese ? "连接你的 dot" : "Connect your dot";
    const detail = chinese ? "读取伴随软件消息并回传回复；仅在你请求同步时，接收已授权 Your dot 房间最近最多30条文字记录，保存到你自己的伴随软件云端。不读取其他聊天、附件、文件，不开放终端或审批权限。" : "Read companion messages and send replies back. On your explicit sync request, receive up to 30 recent text messages from your authorized Your dot room into your own companion cloud. No other chats, attachments, files, terminal, or approval access.";
    const confirm = chinese ? "首次连接需要在 Mac 上确认下面的连接编号，然后点击允许。日常消息收发无需 Mac 在线。" : "Confirm this connection ID on your Mac, then select Allow. The Mac is not needed for everyday message delivery.";
    return page(`<h1>${title}</h1><p>${detail}</p><p>${escape(description.clientName)} · ${escape(description.clientDomain ?? "")}</p><small>${chinese ? "授权返回至" : "Authorization returns to"} ${escape(description.redirectHost)}</small><p>${confirm}</p><code>${intent}</code><form method="post" action="/authorize"><input type="hidden" name="handle" value="${escape(consent.handle)}"><input type="hidden" name="intent" value="${intent}"><button name="decision" value="allow">${chinese ? "允许" : "Allow"}</button><button name="decision" value="deny">${chinese ? "取消" : "Cancel"}</button></form>`, consent.headers, chinese);
  }
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (request.headers.get("Origin") !== issuer) return json({ error: "invalid_origin" }, 403);
  const form = await boundedForm(request);
  if (form.decision === "deny") {
    const denied = await api.denyConsent(request, form.handle);
    return authorizationResponse(request, denied.headers, denied.redirectTo);
  }
  if (form.decision !== "allow") throw new EventError("invalid_form");
  // Possession of the owner-only Mac credential is required as well as the
  // library's browser-bound, single-use consent cookie. No anonymous grants.
  requireResult(await inbox.execute({ kind: "owner_consume", input: { id: form.intent, hash: await digest(form.handle) } }));
  const approved = await api.approveConsent(request, form.handle); checkRequest(approved.request);
  const complete = await api.completeAuthorization({ request: approved.request, userId: env.EVENTS_OWNER,
    scope: approved.request.scope, props: { owner: env.EVENTS_OWNER }, metadata: { name: "Codex Control Dot Inbox" } });
  return authorizationResponse(request, approved.headers, complete.redirectTo);
}
// One immutable closure per incoming request. Do not put timestamps in global
// mutable state, headers or MCP arguments, and do not cache authorization.
const resourceServerFor = (receivedAt: number) => new OAuthResourceServer<DotEventsEnv, OwnerProps>({
  resourceMetadata: { resource, authorization_servers: [issuer], resource_name: "Codex Control Dot Inbox" },
  requiredScopes: scopes,
  validateToken: env => (audience, token) => authorizationServer.validateToken<OwnerProps>(audience, token, env),
  handler: {
    async fetch(request, env, ctx) {
      if (!scopes.every(scope => ctx.auth.scope.includes(scope))) return insufficientScope(ctx.auth, scopes);
      if (ctx.auth.userId !== env.EVENTS_OWNER || ctx.props?.owner !== env.EVENTS_OWNER || ctx.auth.clientId !== chatGPTClient) return json({ error: "wrong_owner" }, 403);
      const token = await authorizationServer.getOAuthApi(env).unwrapToken<OwnerProps>(ctx.auth.token);
      if (!token) return json({ error: "authorization_revoked" }, 401);
      const auth = { owner: token.userId, grant: token.grantId, client: ctx.auth.clientId };
      if (!await grantIsActive(env, auth)) return json({ error: "authorization_revoked" }, 401);
      const authorizedAt = Date.now();
      if (new URL(request.url).pathname !== "/mcp") return json({ error: "not_found" }, 404);
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      if (request.headers.get("Content-Type")?.split(";")[0] !== "application/json") return json({ error: "unsupported_media_type" }, 415);
      const body = await boundedJSON(request.body, 64 * 1024);
      const method = body && typeof body === "object" && "method" in body ? body.method : undefined;
      if (typeof method === "string" && ["events/list", "events/subscribe", "events/unsubscribe", "tools/list", "initialize", "server/discover"].includes(method)) {
        requireResult(await env.EVENT_INBOXES.getByName(env.EVENTS_OWNER).execute({ kind: "event_request", method }));
      }
      // Plugin discovery may still use the 2025 initialize handshake even when
      // event delivery uses modern envelopes. Both eras use the same tools and
      // the OAuth/grant checks above; no sessions or alternate auth are added.
      const handler = createMcpHandler(() => serverFor(env.EVENT_INBOXES.getByName(env.EVENTS_OWNER), auth,
        { receivedAt, authorizedAt }), { legacy: "stateless" });
      return await handler.fetch(request, { parsedBody: body });
    },
  },
});
export default {
  async fetch(request: Request, env: DotEventsEnv, ctx: ExecutionContext): Promise<Response> {
    const receivedAt = Date.now();
    const url = new URL(request.url);
    if (env.EVENTS_MODE !== "authenticated-events" || url.origin !== issuer) return json({ error: "invalid_host" }, 403);
    if (request.headers.has("Host") && request.headers.get("Host") !== url.host) return json({ error: "invalid_host" }, 403);
    const origin = request.headers.get("Origin");
    if (origin && origin !== issuer) return json({ error: "invalid_origin" }, 403);
    try {
      if (url.pathname === "/health") return json({ ok: true, transport: "mcp-events", realDotVerified: false });
      if (url.pathname === "/authorize") return await authorize(request, env);
      if (url.pathname.startsWith("/.well-known/oauth-protected-resource") || url.pathname.startsWith("/mcp")) return await resourceServerFor(receivedAt).fetch(request, env, ctx);
      if (url.pathname.startsWith("/.well-known/") || url.pathname.startsWith("/oauth/") || url.pathname === "/register") return await authorizationServer.fetch(request, env, ctx);
      const admin = url.pathname.startsWith("/admin/");
      if (!await authorized(request, admin ? env.EVENTS_ADMIN_KEY : env.EVENTS_DEVICE_KEY)) return json({ error: "unauthorized" }, 401);
      const inbox = env.EVENT_INBOXES.getByName(env.EVENTS_OWNER);
      if (admin) {
        if (url.pathname === "/admin/dns-check" && request.method === "GET") {
          // A fixed public-domain health check cannot be used as a DNS oracle
          // or to disclose the real callback hostname, addresses or secrets.
          try {
            const addresses = await resolveCallbackAddresses("example.com");
            return json({ ok: addresses.length > 0 && addresses.every(publicAddress), count: addresses.length });
          } catch (error) {
            return json({ ok: false, reason: error instanceof EventError ? error.dnsReason ?? "transport" : "transport" });
          }
        }
        if (url.pathname === "/admin/diagnostics" && request.method === "GET") return response(await inbox.execute({ kind: "diagnostics" }));
        if (url.pathname === "/admin/stability" && request.method === "POST") return response(await inbox.execute({ kind: "observation_start", input: await boundedJSON(request.body, 4096) }));
        const observation = url.pathname.match(/^\/admin\/stability\/([a-f0-9-]{36})$/i);
        if (observation && request.method === "GET") return response(await inbox.execute({ kind: "observation_status", id: observation[1] }));
        if (url.pathname === "/admin/pending" && request.method === "GET") return response(await inbox.execute({ kind: "owner_pending" }));
        if (url.pathname === "/admin/approve" && request.method === "POST") return response(await inbox.execute({ kind: "owner_approve", input: await boundedJSON(request.body, 16 * 1024) }));
        return json({ error: "not_found" }, 404);
      }
      if (url.pathname === "/v2/status" && request.method === "GET") return response(await inbox.execute({ kind: "status" }));
      if (url.pathname === "/v2/threads" && request.method === "GET") return response(await inbox.execute({ kind: "threads", cursor: url.searchParams.get("cursor") ?? undefined }));
      if (url.pathname === "/v2/messages" && request.method === "GET") return response(await inbox.execute({ kind: "timeline", cursor: url.searchParams.get("cursor") ?? undefined }));
      if (url.pathname === "/v3/messages" && request.method === "GET") return response(await inbox.execute({ kind: "shared_history", cursor: url.searchParams.get("cursor") ?? undefined }));
      if (url.pathname === "/v3/sync" && request.method === "POST") return response(await inbox.execute({ kind: "sync_request", input: await boundedJSON(request.body, 4096) }));
      const sync = url.pathname.match(/^\/v3\/sync\/([a-f0-9-]{36})$/i);
      if (sync && request.method === "GET") return response(await inbox.execute({ kind: "sync_status", id: sync[1] }));
      const messages = url.pathname.match(/^\/v2\/threads\/([a-f0-9-]{36})\/messages$/i);
      if (messages && request.method === "GET") return response(await inbox.execute({ kind: "messages", id: messages[1], cursor: url.searchParams.get("cursor") ?? undefined }));
      if (url.pathname === "/v2/messages" && request.method === "POST") {
        const input = commandSchema.safeParse(await boundedJSON(request.body, 64 * 1024));
        if (!input.success) throw new EventError("invalid_params");
        return response(await inbox.execute({ kind: "send", input: input.data }));
      }
      const receipt = url.pathname.match(/^\/v2\/receipts\/([a-f0-9-]{36})$/i), thread = url.pathname.match(/^\/v2\/threads\/([a-f0-9-]{36})$/i);
      if (receipt && request.method === "GET") return response(await inbox.execute({ kind: "receipt", id: receipt[1] }));
      if (thread && request.method === "GET") return response(await inbox.execute({ kind: "thread", id: thread[1] }));
      return json({ error: "not_found" }, 404);
    } catch (error) {
      if (error instanceof AuthorizationError && error.redirectTo) return new Response(null, { status: 303, headers: { ...noStore, Location: error.redirectTo } });
      const quota = durableReadQuotaFailure(error);
      if (quota) return Response.json({ error: quota.error, retryAfter: quota.retryAfter }, {
        status: quota.status, headers: { ...noStore, "Retry-After": String(quota.retryAfter) },
      });
      return json({ error: error instanceof EventError || error instanceof GatewayError ? error.code : "events_unavailable" },
        error instanceof EventError || error instanceof GatewayError ? error.status : 503);
    }
  },
} satisfies ExportedHandler<DotEventsEnv>;
