// All identities, grants, and request payloads here are local test fixtures.
// None are the user's real ChatGPT connection or a real dot response.
import { env, exports } from "cloudflare:workers";
import { reset, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { http } from "msw";
import { network } from "../network";
import { authorizationServer, issuer, resource, chatGPTClient, chatGPTRedirect } from "../../src/events/auth-core";

const device = "fixture-device-key", admin = "fixture-admin-key";
const verifier = "v".repeat(64);
const request = (path: string, init?: RequestInit) => exports.default.fetch(issuer + path, { redirect: "manual", ...init });
const api = () => authorizationServer.getOAuthApi(env);
function bearer(key: string) { return { Authorization: `Bearer ${key}`, "Content-Type": "application/json" }; }
async function authorizeURL(changes: Record<string, string> = {}) {
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  const challenge = btoa(String.fromCharCode(...new Uint8Array(hash))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
  return "/authorize?" + new URLSearchParams({ response_type: "code", client_id: chatGPTClient, redirect_uri: chatGPTRedirect,
    scope: "wearable:inbox offline_access", resource, state: "fixture-only", code_challenge: challenge, code_challenge_method: "S256", ...changes });
}
async function start() {
  const response = await request(await authorizeURL()), html = await response.text();
  expect(response.status, html).toBe(200);
  const handle = html.match(/name="handle" value="([^"]+)"/)![1], intent = html.match(/name="intent" value="([^"]+)"/)![1];
  const cookie = response.headers.get("Set-Cookie")!.split(";")[0];
  return { handle, intent, cookie, html };
}
const confirm = (intent: string, key = admin) => request("/admin/approve", { method: "POST", headers: bearer(key), body: JSON.stringify({ id: intent }) });
const consent = (c: Awaited<ReturnType<typeof start>>, decision = "allow", overrides: RequestInit = {}) => request("/authorize", {
  method: "POST", headers: { Origin: issuer, Cookie: c.cookie, "Content-Type": "application/x-www-form-urlencoded" },
  body: new URLSearchParams({ handle: c.handle, intent: c.intent, decision }).toString(), ...overrides,
});
async function exchange(code: string, changes: Record<string, string> = {}) {
  return request("/oauth/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", client_id: chatGPTClient, redirect_uri: chatGPTRedirect,
      code, code_verifier: verifier, resource, ...changes }).toString() });
}
async function connected() {
  const c = await start(); expect((await confirm(c.intent)).status).toBe(200);
  const accepted = await consent(c); expect(accepted.status, await accepted.clone().text()).toBe(303);
  const location = new URL(accepted.headers.get("Location")!); expect(location.searchParams.get("iss")).toBe(issuer);
  const result = await exchange(location.searchParams.get("code")!); expect(result.status, await result.clone().text()).toBe(200);
  return await result.json() as { access_token: string; refresh_token: string };
}
function rpc(key: string, method = "server/discover", extra: Record<string, unknown> = {}, headers: Record<string, string> = {}) {
  return request("/mcp", { method: "POST", headers: { ...bearer(key), Accept: "application/json, text/event-stream",
    "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": method,
    ...(typeof extra.name === "string" ? { "Mcp-Name": extra.name } : {}), ...headers },
    body: JSON.stringify({ jsonrpc: "2.0", id: crypto.randomUUID(), method, params: { ...extra,
      _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientInfo": { name: "auth-fixture", version: "1" }, "io.modelcontextprotocol/clientCapabilities": {} } } }) });
}
// Seed intentionally invalid grants through the library helper only in this
// isolated test. No production HTTP endpoint can call completeAuthorization.
async function seed(scope: string[], owner: string, props: Record<string, unknown>) {
  const auth = await api().parseAuthRequest(new Request(issuer + await authorizeURL()));
  const complete = await api().completeAuthorization({ request: auth, userId: owner, scope, metadata: {}, props });
  const token = await exchange(new URL(complete.redirectTo).searchParams.get("code")!);
  expect(token.status).toBe(200); return (await token.json() as { access_token: string }).access_token;
}
beforeEach(() => network.use(http.get(chatGPTClient, () => Response.json({ client_id: chatGPTClient, client_name: "ChatGPT <fixture>",
  redirect_uris: [chatGPTRedirect], token_endpoint_auth_method: "none", grant_types: ["authorization_code", "refresh_token"], response_types: ["code"] },
  { headers: { "Cache-Control": "no-store" } }))));
afterEach(async () => { await reset(); });

describe("private OAuth connection (mock identity, no real dot)", () => {
  it("publishes required scope, issuer, PKCE, and CIMD discovery", async () => {
    const discovery = await request("/.well-known/oauth-authorization-server"); expect(discovery.status).toBe(200);
    expect(await discovery.json()).toMatchObject({ issuer, authorization_endpoint: `${issuer}/authorize`, token_endpoint: `${issuer}/oauth/token`,
      client_id_metadata_document_supported: true, authorization_response_iss_parameter_supported: true, code_challenge_methods_supported: ["S256"] });
    const protectedResource = await request("/.well-known/oauth-protected-resource/mcp"); expect(protectedResource.status).toBe(200);
    expect(await protectedResource.json()).toMatchObject({ resource, authorization_servers: [issuer], scopes_supported: ["wearable:inbox"] });
    const unauth = await request("/mcp"); expect(unauth.status).toBe(401);
    expect(unauth.headers.get("WWW-Authenticate")).toContain("oauth-protected-resource/mcp");
  });
  it("device and admin keys cannot access the MCP resource or each other's routes", async () => {
    expect((await request("/mcp", { headers: bearer(device) })).status).toBe(401);
    expect((await request("/admin/pending", { headers: bearer(device) })).status).toBe(401);
    expect((await request("/admin/diagnostics", { headers: bearer(device) })).status).toBe(401);
    expect((await request("/admin/dns-check", { headers: bearer(device) })).status).toBe(401);
    const observationID = crypto.randomUUID();
    expect((await request("/admin/stability/" + observationID, { headers: bearer(device) })).status).toBe(401);
    expect((await request("/admin/stability", { method: "POST", headers: bearer(device), body: "{}" })).status).toBe(401);
    expect((await request("/admin/stability/" + observationID, { headers: bearer(admin) })).status).toBe(404);
    expect((await request("/v2/status", { headers: bearer(admin) })).status).toBe(401);
    expect((await request("/v2/status", { headers: bearer(device) })).status).toBe(200);
    expect((await request("/admin/pending", { headers: bearer(admin) })).status).toBe(200);
    expect((await request("/admin/diagnostics", { headers: bearer(admin) })).status).toBe(200);
  });
  it("restricts DNS health diagnostics to a fixed public hostname and returns no addresses", async () => {
    network.use(http.get("https://cloudflare-dns.com/dns-query", ({ request }) => {
      const url = new URL(request.url), type = Number(url.searchParams.get("type"));
      expect(url.searchParams.get("name")).toBe("example.com");
      expect(request.headers.get("Authorization")).toBeNull();
      expect(request.redirect).toBe("manual");
      return Response.json({ Status: 0, TC: false, Question: [{ name: "example.com.", type }],
        Answer: [{ name: "example.com.", type, TTL: 30, data: type === 1 ? "8.8.8.8" : "2606:4700:4700::1111" }] });
    }));
    const result = await request("/admin/dns-check?hostname=secret.invalid", { headers: bearer(admin) });
    expect(result.status).toBe(200);
    expect(await result.json()).toEqual({ ok: true, count: 2 });
  });
  it("does not expose an anonymous fixed-owner grant and safely escapes client text", async () => {
    const c = await start(); expect(c.html).not.toContain("ChatGPT <fixture>"); expect(c.html).toContain("ChatGPT &lt;fixture&gt;");
    expect((await consent(c)).status).toBe(403); expect((await api().listUserGrants(env.EVENTS_OWNER)).items).toHaveLength(0);
    expect((await confirm(c.intent, device)).status).toBe(401);
    const pending = await (await request("/admin/pending", { headers: bearer(admin) })).json();
    expect(pending).toMatchObject({ requests: [{ id: c.intent, approved: 0 }] });
    expect(JSON.stringify(pending)).not.toContain(c.handle);
  });
  it("requires the matching browser cookie even after owner confirmation", async () => {
    const c = await start(); await confirm(c.intent);
    const wrong = await consent(c, "allow", { headers: { Origin: issuer, "Content-Type": "application/x-www-form-urlencoded" } });
    expect(wrong.status).not.toBe(200); expect((await api().listUserGrants(env.EVENTS_OWNER)).items).toHaveLength(0);
  });
  it("supports visible JSON form feedback without removing owner or cookie checks", async () => {
    const c = await start(), headers = { Origin: issuer, Cookie: c.cookie, Accept: "application/json", "Content-Type": "application/x-www-form-urlencoded" };
    expect((await consent(c, "allow", { headers })).status).toBe(403);
    await confirm(c.intent);
    const accepted = await consent(c, "allow", { headers }); expect(accepted.status).toBe(200);
    const url = new URL((await accepted.json() as { redirect: string }).redirect);
    expect(url.origin).toBe("https://chatgpt.com"); expect(url.pathname).toBe("/connector_platform_oauth_redirect");
    expect((await exchange(url.searchParams.get("code")!)).status).toBe(200);
    expect((await consent(c, "allow", { headers })).status).toBe(403);
  });
  it("rejects foreign browser Origins", async () => {
    const c = await start(); await confirm(c.intent);
    expect((await consent(c, "allow", { headers: { Origin: "https://evil.example", Cookie: c.cookie, "Content-Type": "application/x-www-form-urlencoded" } })).status).toBe(403);
    expect((await api().listUserGrants(env.EVENTS_OWNER)).items).toHaveLength(0);
  });
  it("supports denial and issuer identification without Mac confirmation", async () => {
    const c = await start(), denied = await consent(c, "deny"); expect(denied.status, await denied.clone().text()).toBe(303);
    const url = new URL(denied.headers.get("Location")!);
    expect(url.searchParams.get("error")).toBe("access_denied"); expect(url.searchParams.get("iss")).toBe(issuer);
    expect((await api().listUserGrants(env.EVENTS_OWNER)).items).toHaveLength(0);
  });
  it("exchanges a PKCE code once, allows refresh, and rejects device use of MCP token", async () => {
    const tokens = await connected();
    expect((await request("/v2/status", { headers: bearer(tokens.access_token) })).status).toBe(401);
    expect((await rpc(tokens.access_token)).status).toBe(200);
    const refreshed = await request("/oauth/token", { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "refresh_token", client_id: chatGPTClient, refresh_token: tokens.refresh_token, resource }).toString() });
    expect(refreshed.status).toBe(200); const rotated = await refreshed.json() as { access_token: string };
    expect(rotated.access_token).not.toBe(tokens.access_token);
  });
  it("discovers only five bounded messaging/history tools and can read the authenticated inbox", async () => {
    const tokens = await connected();
    const discovery = await rpc(tokens.access_token); expect(discovery.status).toBe(200);
    expect(await discovery.json()).toMatchObject({ result: { capabilities: { events: {}, tools: {} } } });
    const tools = await (await rpc(tokens.access_token, "tools/list")).json() as { result: { tools: { name: string; _meta: Record<string, unknown> }[] } };
    expect(tools.result.tools.map(tool => tool.name).sort()).toEqual(["get_wearable_inbox", "read_wearable_conversation", "read_wearable_thread", "reply_to_wearable_message", "sync_your_dot_history"]);
    expect(tools.result.tools.every(tool => JSON.stringify(tool._meta).includes("wearable:inbox"))).toBe(true);
    const pending = await rpc(tokens.access_token, "tools/call", { name: "get_wearable_inbox", arguments: {} });
    expect(pending.status).toBe(200);
    expect(await pending.json()).toMatchObject({ result: { content: [{ type: "text", text: '{"messages":[],"truncated":false,"syncRequests":[]}' }] } });
    const diagnostic = await (await request("/admin/diagnostics", { headers: bearer(admin) })).json();
    expect(diagnostic).toMatchObject({ requests: expect.arrayContaining([{ method: "tool:get_wearable_inbox", count: 1, at: expect.any(Number) }]) });
  });
  it("records only bounded event method metadata behind the admin credential", async () => {
    const tokens = await connected();
    await rpc(tokens.access_token, "events/list");
    await rpc(tokens.access_token, "events/subscribe", { malicious: "fixture-sensitive-payload" });
    const data = await (await request("/admin/diagnostics", { headers: bearer(admin) })).json();
    expect(data).toMatchObject({ requests: [{ method: "events/list", count: 1 }, { method: "events/subscribe", count: 1 }], subscription: null, subscriptionIntents: 0, subscribed: false });
    expect(JSON.stringify(data)).not.toContain(tokens.access_token);
    expect(JSON.stringify(data)).not.toContain("fixture-sensitive-payload");
  });
  it("retains all OAuth checks while recording server-only request ingress for a tool read", async () => {
    const tokens = await connected(), id = crypto.randomUUID(), accepted = Date.now();
    await runInDurableObject(env.EVENT_INBOXES.getByName(env.EVENTS_OWNER), async (_, state) => {
      state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state) VALUES (?, ?, 'fixture', ?, 'fixture', 'delivered')", id, id, accepted);
      state.storage.sql.exec("INSERT INTO message_timings (id, accepted_at) VALUES (?, ?)", id, accepted);
    });
    const tool = { name: "read_wearable_thread", arguments: { thread_id: id } };
    expect((await rpc(device, "tools/call", tool)).status).toBe(401);
    const before = Date.now();
    const response = await rpc(tokens.access_token, "tools/call", tool, { "X-MCP-Received-At": "1", "X-MCP-Authorized-At": "2" });
    expect(response.status).toBe(200);
    const body = await response.json() as { result: { content: { text: string }[] } };
    const timing = JSON.parse(body.result.content[0].text).messages[0].timing;
    expect(timing.mcpReceivedAt).toBeGreaterThanOrEqual(before);
    expect(timing.mcpAuthorizedAt).toBeGreaterThanOrEqual(timing.mcpReceivedAt);
    expect(timing.readAt).toBeGreaterThanOrEqual(timing.mcpAuthorizedAt);
    expect(JSON.stringify(timing)).not.toContain(tokens.access_token);
    const grants = await api().listUserGrants(env.EVENTS_OWNER);
    await api().revokeGrant(grants.items[0].id, env.EVENTS_OWNER);
    expect((await rpc(tokens.access_token, "tools/call", tool)).status).toBe(401);
  });
  it("enforces the scope in the handler, not just in discovery metadata", async () => {
    const token = await seed([], env.EVENTS_OWNER, { owner: env.EVENTS_OWNER });
    const result = await rpc(token); expect(result.status).toBe(403);
    expect(result.headers.get("WWW-Authenticate")).toContain("insufficient_scope");
  });
  it("rejects tokens bound to another owner or malformed owner properties", async () => {
    expect((await rpc(await seed(["wearable:inbox"], "foreign-fixture", { owner: "foreign-fixture" }))).status).toBe(403);
    expect((await rpc(await seed(["wearable:inbox"], env.EVENTS_OWNER, { owner: "foreign-fixture" }))).status).toBe(403);
  });
  it("does not exchange an authorization code twice", async () => {
    const c = await start(); await confirm(c.intent); const accepted = await consent(c);
    const code = new URL(accepted.headers.get("Location")!).searchParams.get("code")!;
    expect((await exchange(code)).status).toBe(200); expect((await exchange(code)).status).toBe(400);
  });
  it("rejects a bad PKCE verifier, wrong audience, and replayed consent", async () => {
    const c = await start(); await confirm(c.intent); const accepted = await consent(c);
    const code = new URL(accepted.headers.get("Location")!).searchParams.get("code")!;
    expect((await exchange(code, { code_verifier: "x".repeat(64) })).status).toBe(400);
    expect((await consent(c)).status).toBe(403);
    expect((await request(await authorizeURL({ resource: "https://evil.example/mcp" }))).status).not.toBe(200);
    expect((await request(await authorizeURL({ code_challenge_method: "plain" }))).status).not.toBe(200);
  });
  it("revokes the grant and rejects subsequent MCP access", async () => {
    const tokens = await connected(), grants = await api().listUserGrants(env.EVENTS_OWNER);
    expect(grants.items).toHaveLength(1); await api().revokeGrant(grants.items[0].id, env.EVENTS_OWNER);
    expect((await request("/mcp", { headers: bearer(tokens.access_token) })).status).toBe(401);
  });
  it("keeps owner-confirmation intents single-use and expires them", async () => {
    const c = await start(); await confirm(c.intent);
    await runInDurableObject(env.EVENT_INBOXES.getByName(env.EVENTS_OWNER), async (_instance, state) => state.storage.sql.exec("UPDATE owner_consents SET expires_at = ?", Date.now() - 1));
    expect((await consent(c)).status).toBe(403); expect((await api().listUserGrants(env.EVENTS_OWNER)).items).toHaveLength(0);
  });
});
