import { env, exports } from "cloudflare:workers";
import { evictDurableObject, reset } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { http } from "msw";
import { network } from "./network";

const root = "1791343731.898569";
const posted = "1791343958.737019";
let calls: { method: string; body: Record<string, unknown>; request: Request }[];
let overrides: Record<string, () => Response | Promise<Response>>;
const json = (value: unknown) => Response.json(value);
const message = (user: string, ts = root, text = "测试🙂") => ({ user, ts, text });
function query(path: string, body?: unknown, key = "local-test-dots-key") {
  return exports.default.fetch(`https://test.local${path}`, {
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    ...(body ? { method: "POST", body: JSON.stringify(body) } : {}),
  });
}
const command = (text = "你好，你是什么模型？🙂", thread?: string) => ({ id: crypto.randomUUID(), text, createdAt: Date.now(), ...(thread ? { thread } : {}) });

beforeEach(() => {
  calls = [];
  overrides = {};
  network.use(http.all("https://slack.com/api/:method", async ({ request }) => {
    const url = new URL(request.url);
    expect(url.origin).toBe("https://slack.com");
    expect(request.redirect).toBe("manual");
    expect(request.headers.get("Authorization")).toBe("Bearer xoxp-local-test");
    const method = url.pathname.split("/").at(-1)!;
    const body = request.method === "POST" ? await request.json() as Record<string, unknown> : Object.fromEntries(url.searchParams);
    calls.push({ method, body, request });
    if (overrides[method]) return overrides[method]();
    if (method === "auth.test") return json({ ok: true, user_id: env.SLACK_OWNER_ID, team_id: env.SLACK_TEAM_ID });
    if (method === "conversations.info") return json({ ok: true, channel: { id: env.SLACK_DOT_CHANNEL, is_im: true, user: env.SLACK_DOT_ID } });
    if (method === "conversations.history") return json({ ok: true, messages: [message(env.SLACK_OWNER_ID)], response_metadata: {} });
    if (method === "conversations.replies") return json({ ok: true, messages: [message(env.SLACK_OWNER_ID), message(env.SLACK_DOT_ID, posted, "已记住星河-834🙂")], response_metadata: {} });
    if (method === "chat.postMessage") return json({ ok: true, channel: env.SLACK_DOT_CHANNEL, ts: posted });
    throw new Error("Unexpected method");
  }));
});
afterEach(async () => { await reset(); });

describe("isolated dot gateway", () => {
  it("intercepts Slack requests in the runtime", async () => {
    const response = await fetch("https://slack.com/api/auth.test", { redirect: "manual", headers: { Authorization: "Bearer xoxp-local-test" } });
    expect(await response.json()).toMatchObject({ ok: true, team_id: env.SLACK_TEAM_ID });
    expect(calls).toHaveLength(1);
  });
  it("health contains no account, token or conversation", async () => {
    const response = await query("/health", undefined, "");
    expect(await response.json()).toEqual({ ok: true, protocol: 1 });
    expect(calls).toHaveLength(0);
  });
  it("rejects unauthenticated requests before accessing Slack", async () => {
    expect((await query("/v1/threads", undefined, "wrong")).status).toBe(401);
    expect(calls).toHaveLength(0);
  });
  it("does not expose Codex commands or approval endpoints", async () => {
    expect((await query("/v1/approvals", { decision: "accept" })).status).toBe(404);
    expect(calls).toHaveLength(0);
  });
  it("verifies the actual Slack user and workspace", async () => {
    overrides["auth.test"] = () => json({ ok: true, team_id: "TOTHER", user_id: env.SLACK_OWNER_ID });
    const response = await query("/v1/connection");
    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ error: "account_mismatch" });
  });
  it("fails closed if the DM belongs to anyone other than the dot", async () => {
    overrides["conversations.info"] = () => json({ ok: true, channel: { id: env.SLACK_DOT_CHANNEL, is_im: true, user: "UOTHER" } });
    expect((await query("/v1/connection")).status).toBe(403);
  });
  it("posts exact Unicode and an explicit dot mention without keyboard automation", async () => {
    const input = command("你好，你是什么模型？🙂 <@UOTHER> & 3 < 5");
    const response = await query("/v1/messages", input);
    expect(await response.json()).toMatchObject({ id: input.id, state: "sent", thread: posted });
    const write = calls.find(x => x.method === "chat.postMessage")!;
    expect(write.body).toMatchObject({ channel: env.SLACK_DOT_CHANNEL, text: `<@${env.SLACK_DOT_ID}> 你好，你是什么模型？🙂 &lt;@UOTHER&gt; &amp; 3 &lt; 5`, mrkdwn: true, parse: "none", unfurl_links: false, unfurl_media: false });
  });
  it("deduplicates concurrent and repeated requests", async () => {
    const input = command();
    await Promise.all([query("/v1/messages", input), query("/v1/messages", input)]);
    await query("/v1/messages", input);
    expect(calls.filter(x => x.method === "chat.postMessage")).toHaveLength(1);
  });
  it("rejects reuse of an ID with different content", async () => {
    const input = command(); await query("/v1/messages", input);
    expect((await query("/v1/messages", { ...input, text: "不同内容" })).status).toBe(409);
  });
  it("keeps follow-ups in the same dot thread and includes the mention", async () => {
    await query("/v1/messages", command("继续，不要使用工具。", root));
    const write = calls.find(x => x.method === "chat.postMessage")!;
    expect(write.body.thread_ts).toBe(root);
    expect(write.body.text).toBe(`<@${env.SLACK_DOT_ID}> 继续，不要使用工具。`);
  });
  it("restores provider Unicode emoji without fetching custom assets", async () => {
    overrides["conversations.replies"] = () => json({ ok: true, messages: [{
      user: env.SLACK_OWNER_ID, ts: root, text: `<@${env.SLACK_DOT_ID}> 中文 :slightly_smiling_face: :custom: &lt;3`,
      app_id: "AEXAMPLE", bot_id: "BEXAMPLE",
      blocks: [{ type: "rich_text", elements: [{ type: "rich_text_section", elements: [
        { type: "emoji", name: "slightly_smiling_face", unicode: "1f642" },
        { type: "emoji", name: "custom", url: "https://untrusted.example/emoji.png" },
      ] }] }],
    }] });
    const result = await (await query(`/v1/threads/${root}`)).json();
    expect(result).toMatchObject({ messages: [{ text: "中文 🙂 :custom: <3" }] });
    expect(JSON.stringify(result)).not.toContain("BEXAMPLE");
    expect(calls.map(c => c.method)).toEqual(["auth.test", "conversations.info", "conversations.replies"]);
  });
  it("does not decode invalid Unicode or executable action payloads", async () => {
    overrides["conversations.replies"] = () => json({ ok: true, messages: [{
      user: env.SLACK_OWNER_ID, ts: root, text: ":invalid: :action:",
      blocks: [
        { type: "rich_text", elements: [{ type: "emoji", name: "invalid", unicode: "d800" }] },
        { type: "actions", elements: [{ type: "emoji", name: "action", unicode: "1f642" }] },
      ],
    }] });
    expect(await (await query(`/v1/threads/${root}`)).json()).toMatchObject({ messages: [{ text: ":invalid: :action:", controlsInSlack: true }] });
  });
  it("uses the standard emoji catalogue when rich_text metadata is absent", async () => {
    overrides["conversations.replies"] = () => json({ ok: true, messages: [message(env.SLACK_OWNER_ID, root, "中文 :slightly_smiling_face: :wave::skin-tone-3: :unknown_custom:")] });
    expect(await (await query(`/v1/threads/${root}`)).json()).toMatchObject({ messages: [{ text: "中文 🙂 👋🏼 :unknown_custom:" }] });
  });
  it("preserves rate limits and retry headers across DO RPC", async () => {
    overrides["conversations.history"] = () => new Response(null, { status: 429, headers: { "Retry-After": "47" } });
    const response = await query("/v1/threads");
    expect(response.status).toBe(429);
    expect(response.headers.get("Retry-After")).toBe("47");
    expect(await response.json()).toEqual({ error: "rate_limited", retryAfter: 47 });
  });
  it("never automatically resends an ambiguous post", async () => {
    overrides["chat.postMessage"] = () => json({ ok: false, error: "internal_error" });
    const input = command();
    expect(await (await query("/v1/messages", input)).json()).toMatchObject({ state: "uncertain" });
    expect(await (await query("/v1/messages", input)).json()).toMatchObject({ state: "uncertain" });
    expect(calls.filter(x => x.method === "chat.postMessage")).toHaveLength(1);
  });
  it("retains the receipt after an eviction", async () => {
    const input = command(); await query("/v1/messages", input);
    const account = env.DOT_ACCOUNTS.getByName(`${env.SLACK_TEAM_ID}:${env.SLACK_OWNER_ID}`);
    await evictDurableObject(account);
    expect(await (await query(`/v1/receipts/${input.id}`)).json()).toMatchObject({ state: "sent", thread: posted });
    expect(calls.filter(x => x.method === "chat.postMessage")).toHaveLength(1);
  });
  it("rejects caller-provided channel overrides", async () => {
    expect((await query("/v1/messages", { ...command(), channel: "DOTHER" })).status).toBe(400);
    expect(calls).toHaveLength(0);
  });
  it("does not fabricate task status or formal approvals", async () => {
    const result = await (await query("/v1/connection")).json();
    expect(result).toMatchObject({ capabilities: { messaging: true, runtimeStatus: false, approvals: false } });
  });
  it("rejects oversized requests without reading Slack", async () => {
    expect((await query("/v1/messages", command("a".repeat(70_000)))).status).toBe(413);
    expect(calls).toHaveLength(0);
  });
  it("rejects expired commands before making a provider call", async () => {
    expect((await query("/v1/messages", { ...command(), createdAt: 1 })).status).toBe(400);
    expect(calls).toHaveLength(0);
  });
  it("excludes other authors and returns pagination", async () => {
    overrides["conversations.replies"] = () => json({ ok: true, messages: [message(env.SLACK_OWNER_ID), message("UOTHER", posted, "not allowed")], response_metadata: { next_cursor: "next" } });
    const page = await (await query(`/v1/threads/${root}`)).json();
    expect(page).toMatchObject({ nextCursor: "next" });
    expect((page as { messages: unknown[] }).messages).toHaveLength(1);
  });
  it("rejects invalid thread IDs and unknown pagination roots", async () => {
    expect((await query(`/v1/threads/1791343731.898569?cursor=forged`)).status).toBe(400);
    expect(calls.some(x => x.method === "conversations.replies")).toBe(false);
  });
  it("polls only messages after the latest timestamp, including long threads", async () => {
    await query(`/v1/threads/${root}`);
    overrides["conversations.replies"] = () => json({ ok: true, messages: [message(env.SLACK_DOT_ID, "1791343999.000001", "新的回复")], response_metadata: {} });
    const page = await (await query(`/v1/threads/${root}?after=${posted}`)).json();
    expect(page).toMatchObject({ messages: [{ text: "新的回复" }] });
    expect(calls.filter(x => x.method === "conversations.replies").at(-1)!.body).toMatchObject({ oldest: posted, inclusive: "true" });
  });
  it("never follows a provider redirect or leaks the credential", async () => {
    overrides["auth.test"] = () => new Response(null, { status: 302, headers: { Location: "https://untrusted.example" } });
    expect((await query("/v1/connection")).status).toBe(502);
    expect(calls).toHaveLength(1);
  });
});
