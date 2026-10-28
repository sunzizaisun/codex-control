// All receiver/model activity in this file is a MOCK. It is not evidence that
// a real user dot has subscribed, run a task, or generated a reply.
import { env, exports } from "cloudflare:workers";
import { abortAllDurableObjects, reset, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { http } from "msw";
import { Webhook } from "standardwebhooks";
import { network } from "../network";
import { eventName, type MessageEvent } from "../../src/events/protocol";
import { authorizedDotRoom, DotHistory, sharedHistoryQueries } from "../../src/events/history";
import { durableReadQuotaFailure } from "../../src/events/quota-error";
import { initializeThreadSummaries, threadSummaryPageQuery } from "../../src/events/thread-summary";
import { validRequestTiming } from "../../src/events/request-timing";

const secret = `whsec_${btoa("s".repeat(32))}`;
const callback = "https://mcp-callback.invalid/events/fixture";
const owner = () => env.EVENT_INBOXES.getByName(env.EVENTS_OWNER);
const subscription = (url = callback, key = secret) => ({ name: eventName, arguments: { inbox: "wearable" }, delivery: { mode: "webhook", url, secret: key }, cursor: null });
const command = (text = "你好，你是什么模型？🙂", thread?: string) => ({ id: crypto.randomUUID(), text, createdAt: Date.now(), ...(thread ? { thread } : {}) });
function request(path: string, body?: unknown, key = "fixture-device-key", headers: Record<string, string> = {}, base = "http://localhost") {
  return exports.default.fetch(`${base}${path}`, { headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", ...headers },
    ...(body !== undefined ? { method: "POST", body: JSON.stringify(body) } : {}) });
}
async function rpc(method: string, params: Record<string, unknown> = {}, key = "fixture-mcp-key", headers: Record<string, string> = {}) {
  const response = await request("/mcp", { jsonrpc: "2.0", id: crypto.randomUUID(), method,
    params: { ...params, _meta: { "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": { name: "isolated-fixture", version: "1" }, "io.modelcontextprotocol/clientCapabilities": {} } } }, key,
    { Accept: "application/json, text/event-stream", "MCP-Protocol-Version": "2026-07-28", "Mcp-Method": method,
      ...(method === "tools/call" && typeof params.name === "string" ? { "Mcp-Name": params.name } : {}), ...headers });
  return { status: response.status, body: await response.json() as Record<string, any> };
}
const connect = () => rpc("events/subscribe", subscription());
const send = (input: ReturnType<typeof command>) => request("/v2/messages", input);
const reply = (id: string, text: string) => rpc("tools/call", { name: "reply_to_wearable_message", arguments: { message_id: id, text } });
async function dispatch() {
  await runInDurableObject(owner(), async (_instance, state) => {
    // Never revoke an in-flight native alarm's lease merely to speed a test up.
    state.storage.sql.exec("UPDATE outbox SET due_at = ? WHERE state = 'pending'", Date.now() - 1);
  });
  const ran = await runDurableObjectAlarm(owner());
  // A native alarm can have claimed the job just before this manual trigger.
  // Its I/O is real within the mock runtime and must finish before assertions.
  await expect.poll(() => runInDurableObject(owner(), async (_instance, state) =>
    state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM outbox WHERE state = 'dispatching'").one().count),
  { interval: 5, timeout: 2000 }).toBe(0);
  return ran;
}
let events: MessageEvent[];
let verifications: number;
let status: number;
let badChallenge: boolean;
let receiverHook: ((event: MessageEvent) => Promise<void>) | undefined;

beforeEach(() => {
  events = []; verifications = 0; status = 202; badChallenge = false; receiverHook = undefined;
  network.use(http.post("https://mcp-callback.invalid/events/:id", async ({ request }) => {
    expect(request.redirect).toBe("manual");
    const body = await request.text();
    const payload = new Webhook(secret).verify(body, {
      "webhook-id": request.headers.get("webhook-id")!, "webhook-timestamp": request.headers.get("webhook-timestamp")!,
      "webhook-signature": request.headers.get("webhook-signature")!,
    }) as Record<string, unknown>;
    expect(request.headers.get("X-MCP-Subscription-Id")).toMatch(/^sub_[a-f0-9]{64}$/);
    expect(request.headers.get("Authorization")).toBeNull();
    if (payload.type === "verification") {
      verifications++; return Response.json({ challenge: badChallenge ? "incorrect" : payload.challenge });
    }
    expect(payload.eventId).toBe(request.headers.get("webhook-id"));
    const event = payload as MessageEvent;
    events.push(event); await receiverHook?.(event);
    return new Response(null, { status });
  }));
});
afterEach(async () => { await reset(); });

describe("on-demand official history sync (mock official reader, not real dot)", () => {
  it("only recognizes the confirmed quota failure and bounds read recovery probes without leaking exception text", () => {
    const now = Date.UTC(2026, 9, 12, 16, 30);
    expect(durableReadQuotaFailure(new Error("Exceeded allowed rows read in Durable Objects free tier."), now))
      .toEqual({ error: "cloud_read_quota_exhausted", status: 503, rpcCode: -32603, retryAfter: 900 });
    for (const [at, expected] of [[Date.UTC(2026, 9, 12, 23, 59, 30), 30], [Date.UTC(2026, 9, 13, 0, 10), 900]]) {
      expect(durableReadQuotaFailure(new Error("Exceeded allowed rows read in Durable Objects free tier."), at)?.retryAfter).toBe(expected);
    }
    expect(durableReadQuotaFailure(new Error("other error with private content"), now)).toBeUndefined();
    expect(durableReadQuotaFailure("Exceeded allowed rows read in Durable Objects free tier.", now)).toBeUndefined();
  });
  it("reads only pending rows rather than scanning retained replied history", async () => {
    await request("/v2/status");
    await runInDurableObject(owner(), async (_, state) => {
      const sql = state.storage.sql;
      for (let i = 0; i < 2000; i++) {
        sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state) VALUES (?, 'qa', 'fixture', ?, 'qa', 'replied')", `past-${i}`, Date.now());
      }
      const query = "SELECT * FROM messages WHERE state IN ('queued', 'delivered') ORDER BY sequence LIMIT 51";
      const empty = sql.exec(query); expect(empty.toArray()).toEqual([]);
      expect(empty.rowsRead).toBeLessThan(10);
      for (let i = 0; i < 3; i++) sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state) VALUES (?, 'qa', 'fixture', ?, 'qa', 'delivered')", `pending-${i}`, Date.now());
      const indexed = sql.exec(query); const expected = indexed.toArray(); const indexedReads = indexed.rowsRead;
      expect(expected.map(row => row.id)).toEqual(["pending-0", "pending-1", "pending-2"]);
      expect(indexedReads).toBeLessThan(10);
      // Baseline exists only inside the isolated fixture, never in production.
      sql.exec("DROP INDEX pending_message_page");
      const baseline = sql.exec(query); expect(baseline.toArray()).toEqual(expected);
      expect(baseline.rowsRead).toBeGreaterThanOrEqual(2000);
      console.info(JSON.stringify({ fixtureOnly: true, pendingRows: 3, retainedRows: 2000, indexedReads, unindexedReads: baseline.rowsRead }));
    });
  });
  it("keeps large mixed history pages exact while reading a bounded indexed window", async () => {
    await request("/v2/status");
    await runInDurableObject(owner(), async (_, state) => {
      const sql = state.storage.sql, now = Date.now();
      const expectedRows: { id: string; sentAt: number }[] = [];
      for (let i = 0; i < 2000; i++) {
        const id = `row-${String(i).padStart(5, "0")}`, at = now - Math.floor(i / 4);
        sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state, reply, replied_at) VALUES (?, 'qa', ?, ?, 'qa', 'replied', ?, ?)", id, `用户${i}`, at, `回复${i}`, at);
        sql.exec("INSERT INTO official_dot_messages VALUES (?, 'assistant', ?, ?, ?)", id, `官方${i}`, at, i % 3 ? 1 : 0);
        expectedRows.push({ id: id + ".user", sentAt: at }, { id: id + ".reply", sentAt: at });
        if (i % 3) expectedRows.push({ id: "official." + id, sentAt: at });
      }
      const history = new DotHistory(state.storage);
      // Reproduce the previous unindexed schema only in this local fixture.
      for (const name of ["shared_user_page", "shared_reply_page", "shared_official_page"]) sql.exec(`DROP INDEX ${name}`);
      const baseline = sql.exec(`SELECT * FROM (
        SELECT m.id || '.user' AS id, 'user' AS role, m.text, m.created_at AS sentAt,
          m.state AS deliveryState, t.read_at AS readAt FROM messages m LEFT JOIN message_timings t ON t.id = m.id
        UNION ALL SELECT id || '.reply', 'assistant', reply, replied_at, NULL, NULL FROM messages WHERE reply IS NOT NULL
        UNION ALL SELECT 'official.' || id, role, text, sent_at, NULL, NULL FROM official_dot_messages WHERE visible = 1
      ) WHERE sentAt < ? OR (sentAt = ? AND id < ?) ORDER BY sentAt DESC, id DESC LIMIT 31`, Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, "");
      baseline.toArray(); const unindexedReads = baseline.rowsRead;
      history.initialize();
      expectedRows.sort((a, b) => b.sentAt - a.sentAt || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0));
      let cursor: string | undefined;
      const seen = new Set<string>();
      for (let page = 0; page < 5; page++) {
        const actual = history.timeline(cursor);
        const [time, ...parts] = cursor?.split(".") ?? [];
        const before = time ? Number(time) : Number.MAX_SAFE_INTEGER, id = parts.join(".");
        expect(actual.messages.map(m => m.id)).toEqual(expectedRows.slice(page * 30, (page + 1) * 30).reverse().map(m => m.id));
        let reads = 0;
        for (const query of sharedHistoryQueries) {
          const measured = sql.exec(query, before, id); measured.toArray(); reads += measured.rowsRead;
        }
        if (page === 0) console.info(JSON.stringify({ fixtureOnly: true, unindexedReads, indexedReads: reads, nativeRows: 2000, officialRows: 2000 }));
        expect(reads).toBeLessThan(300);
        expect(reads).toBeLessThan(unindexedReads / 10);
        for (const row of actual.messages) { expect(seen.has(row.id)).toBe(false); seen.add(row.id); }
        expect(actual.nextCursor).not.toBeNull(); cursor = actual.nextCursor!;
      }
      expect(seen.size).toBe(150);
    });
  });
  const trigger = () => ({ id: crypto.randomUUID(), createdAt: Date.now() });
  const fixture = (id = crypto.randomUUID(), role: "user" | "assistant" = "user", text = "原文：海狸-428🍁\nEnglish punctuation?!") => ({ id, role, text, sentAt: Date.now() - 1000 });
  const upload = (id: string, messages: unknown[], extra = {}) => rpc("tools/call", { name: "sync_your_dot_history", arguments: { request_id: id, room_id: authorizedDotRoom, messages, truncated: false, ...extra } });
  const rejected = (result: Awaited<ReturnType<typeof rpc>>) => !!result.body.error || result.body.result?.isError === true;
  async function begin() {
    await connect();
    const input = trigger();
    const result = await (await request("/v3/sync", input)).json() as { id: string };
    return { input, id: result.id };
  }
  it("normalizes history request UUIDs for replay, receipt, import and message collision checks", async () => {
    await connect();
    const input = trigger(), upper = input.id.toUpperCase();
    expect(await (await request("/v3/sync", { ...input, id: upper })).json()).toMatchObject({ id: input.id });
    expect(await (await request("/v3/sync", input)).json()).toMatchObject({ id: input.id });
    expect(await (await request(`/v3/sync/${upper}`)).json()).toMatchObject({ id: input.id });
    expect((await send({ ...command(), id: input.id })).status).toBe(409);
    const imported = await upload(upper, [fixture()]);
    expect(rejected(imported)).toBe(false);
    expect(JSON.parse(imported.body.result.content[0].text)).toMatchObject({ id: input.id, state: "completed" });
    await dispatch(); expect(events.every(event => event.data.request_kind === "history_sync")).toBe(true);
  });
  it("preserves legacy mixed-case history IDs while preventing new identity collisions", async () => {
    const { input, id } = await begin(); await dispatch();
    const legacy = id.toUpperCase();
    await runInDurableObject(owner(), async (_, state) => {
      // A prior version persisted caller-provided UUID casing unchanged.
      for (const table of ["history_sync_requests", "message_timings", "outbox"]) {
        state.storage.sql.exec(`UPDATE ${table} SET id = ? WHERE id = ?`, legacy, id);
      }
    });
    expect(await (await request(`/v3/sync/${id}`)).json()).toMatchObject({ id: legacy });
    expect(await (await request("/v3/sync", input)).json()).toMatchObject({ id: legacy });
    expect((await send({ ...command(), id })).status).toBe(409);
    expect(rejected(await upload(id, [fixture()]))).toBe(false);
    expect(await (await request(`/v3/sync/${legacy}`)).json()).toMatchObject({ id: legacy, state: "completed", deliveryState: "answered" });
  });
  it.each(["message", "sync"])("rolls back the entire %s acceptance when outbox persistence fails", async kind => {
    await connect();
    const input = command("事务恢复测试🙂");
    await runInDurableObject(owner(), async (_, state) => {
      state.storage.sql.exec("CREATE TRIGGER reject_fixture_outbox BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'fixture_outbox_failure'); END");
    });
    const submit = () => kind === "message" ? request("/v2/messages", { ...input, shared: true })
      : request("/v3/sync", { id: input.id, createdAt: input.createdAt });
    expect((await submit()).status).toBe(503);
    await runInDurableObject(owner(), async (_, state) => {
      for (const table of ["messages", "message_timings", "history_sync_requests", "outbox", "conversation_settings"]) {
        expect(state.storage.sql.exec<{ count: number }>(`SELECT COUNT(*) AS count FROM ${table}`).one().count, table).toBe(0);
      }
      state.storage.sql.exec("DROP TRIGGER reject_fixture_outbox");
    });
    expect((await submit()).status).toBe(200);
    await dispatch(); expect(events).toHaveLength(1); expect(events[0].eventId).toBe(input.id);
  });
  it("rejects invalid UTF-8 before it can replace characters in accepted user text", async () => {
    await connect();
    const valid = new TextEncoder().encode(JSON.stringify(command("x")));
    const index = new TextDecoder().decode(valid).indexOf('"text":"x"') + 8;
    valid[index] = 0xff;
    const response = await exports.default.fetch("http://localhost/v2/messages", {
      method: "POST", headers: { Authorization: "Bearer fixture-device-key", "Content-Type": "application/json" }, body: valid,
    });
    expect(response.status).toBe(400); expect(await response.json()).toEqual({ error: "invalid_json" });
    expect(await (await request("/v2/messages")).json()).toMatchObject({ messages: [] });
  });
  it("adds completion timing to an existing history table without losing requests or messages", async () => {
    const { id } = await begin(), message = fixture();
    await upload(id, [message]);
    await runInDurableObject(owner(), async (_, state) => {
      // Simulate the exact prior schema in the isolated test database only.
      state.storage.sql.exec("ALTER TABLE history_sync_requests DROP COLUMN completed_at");
      const upgraded = new DotHistory(state.storage);
      upgraded.initialize(); upgraded.initialize();
      expect(upgraded.status(id)).toMatchObject({ state: "completed", imported: 1, completedAt: null });
      expect(upgraded.timeline().messages).toContainEqual(expect.objectContaining({ id: `official.${message.id}`, text: message.text }));
    });
  });
  it("coalesces concurrent device refreshes without creating chat bubbles or ordinary replies", async () => {
    await connect();
    const inputs = [trigger(), trigger()];
    const receipts = await Promise.all(inputs.map(async input => (await request("/v3/sync", input)).json() as Promise<{ id: string }>));
    expect(receipts[0].id).toBe(receipts[1].id);
    expect(await (await request("/v2/messages")).json()).toMatchObject({ messages: [] });
    expect(await (await request("/v3/messages")).json()).toMatchObject({ messages: [] });
    await dispatch();
    expect(events).toHaveLength(1); expect(events[0].data.request_kind).toBe("history_sync");
    expect(await (await request(`/v3/sync/${receipts[0].id}`)).json()).toMatchObject({ state: "pending", deliveryState: "acknowledged", deliveryAttempts: 1 });
    expect(rejected(await reply(receipts[0].id, "wrong path"))).toBe(true);
    expect((await rpc("tools/call", { name: "get_wearable_inbox", arguments: {} })).body.result.content[0].text).toContain("syncRequests");
  });
  it("imports exact user/reply text once, keeps IDs and never emits feedback events", async () => {
    const { id, input } = await begin();
    const messages = [fixture(), fixture(crypto.randomUUID(), "assistant", "回复：海狸-428🍁")];
    const result = await upload(id, messages);
    expect(result.body.error).toBeUndefined();
    const receipt = JSON.parse(result.body.result.content[0].text);
    expect(receipt).toMatchObject({ state: "completed", imported: 2, duplicates: 0, timing: { acceptedAt: expect.any(Number) } });
    expect(receipt.completedAt).toBeGreaterThanOrEqual(receipt.createdAt);
    const replay = await upload(id, messages);
    expect(replay.body.error).toBeUndefined();
    expect(JSON.parse(replay.body.result.content[0].text).completedAt).toBe(receipt.completedAt);
    const timeline = await (await request("/v3/messages")).json() as { messages: { id: string; text: string; role: string }[] };
    expect(timeline.messages).toHaveLength(2);
    for (const message of messages) expect(timeline.messages).toContainEqual(expect.objectContaining({ ...message, id: `official.${message.id}` }));
    expect(await (await request("/v2/messages")).json()).toMatchObject({ messages: [] });
    expect((await request("/v3/sync", input)).status).toBe(200);
    await dispatch(); expect(events.length).toBeLessThanOrEqual(1);
    expect(events.every(e => e.data.request_kind === "history_sync")).toBe(true);
    const coalesced = await (await request("/v3/sync", trigger())).json() as { id: string };
    expect(coalesced.id).toBe(id);
  });
  it("returns only the completed authorized batch even when it falls behind the latest timeline page", async () => {
    const { id } = await begin();
    const source = command("伴随端原文🦦"); await send(source); await reply(source.id, "真实回执🍁");
    const native = [fixture(crypto.randomUUID(), "user", "官方端早先的消息🦦"), fixture(crypto.randomUUID(), "assistant", "官方端早先的回复🍁")]
      .map((row, index) => ({ ...row, sentAt: Date.now() - 60_000 + index }));
    const mirror = fixture(crypto.randomUUID(), "assistant", `来自手机／手表\n用户：${source.text}\ndot：真实回执🍁\n同步编号：${source.id}`);
    await runInDurableObject(owner(), async (_, state) => {
      for (let index = 0; index < 40; index++) {
        const rowID = crypto.randomUUID();
        state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state) VALUES (?, ?, ?, ?, 'fixture', 'queued')", rowID, rowID, "较新的已存记录", Date.now() - 500 + index);
      }
      state.storage.sql.exec("INSERT INTO official_dot_messages VALUES ('outside_this_batch', 'user', '不得额外返回', ?, 1)", Date.now() - 90_000);
    });
    const imported = await upload(id, [...native, mirror]);
    expect(rejected(imported)).toBe(false);
    const receipt = await (await request(`/v3/sync/${id}`)).json() as { messages: { id: string; text: string }[]; hiddenMessageIDs: string[] };
    expect(receipt.messages).toEqual(native.map(row => ({ ...row, id: "official." + row.id, controlsInSlack: false })));
    expect(receipt.hiddenMessageIDs).toEqual(["official." + mirror.id]);
    const latest = await (await request("/v3/messages")).json() as { messages: { id: string }[] };
    expect(latest.messages.some(row => receipt.messages.some(imported => imported.id === row.id))).toBe(false);
    expect(new Set(receipt.messages.map(row => row.id)).size).toBe(2);
    expect(await (await request(`/v3/sync/${id}`)).json()).toEqual(receipt);
    expect(await (await request("/v3/sync", trigger())).json()).toEqual(receipt);
  });
  it("rejects changed replays, unknown requests, extra scopes/roles, attachments and device writes", async () => {
    const { id } = await begin(); const message = fixture();
    expect(rejected(await upload(crypto.randomUUID(), [message]))).toBe(true);
    for (const extra of [{ room_id: "other" }, { messages: [{ ...message, role: "system" }] }, { messages: [{ ...message, attachment: "x" }] }]) {
      expect(rejected(await upload(id, [message], extra))).toBe(true);
    }
    expect((await request("/mcp", { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "sync_your_dot_history", arguments: {} } })).status).toBe(401);
    expect((await request("/v3/history", { request_id: id, messages: [message] })).status).toBe(404);
    await upload(id, [message]);
    expect(rejected(await upload(id, [{ ...message, text: "modified" }]))).toBe(true);
  });
  it("rejects stale, conflicting and expired requests, including chat/sync ID collisions", async () => {
    const { id, input } = await begin();
    expect((await request("/v3/sync", { ...input, createdAt: input.createdAt + 1 })).status).toBe(409);
    expect((await request("/v3/sync", { ...trigger(), createdAt: Date.now() - 120_000 })).status).toBe(400);
    expect((await send({ ...command(), id })).status).toBe(409);
    await runInDurableObject(owner(), async (_, state) => state.storage.sql.exec("UPDATE history_sync_requests SET expires_at = ?, recover_until = ?", Date.now() - 2, Date.now() - 1));
    const deliveredBeforeExpiry = events.length;
    expect(rejected(await upload(id, [fixture()]))).toBe(true);
    expect(await (await request(`/v3/sync/${id}`)).json()).toMatchObject({ state: "expired" });
    await dispatch(); expect(events).toHaveLength(deliveredBeforeExpiry);
  });
  it("deduplicates original IDs across independent syncs and rolls back a conflicting batch", async () => {
    const { id } = await begin(), first = fixture();
    await upload(id, [first]);
    await runInDurableObject(owner(), async (_, state) => state.storage.sql.exec("UPDATE history_sync_requests SET created_at = ?", Date.now() - 61_000));
    const next = await (await request("/v3/sync", trigger())).json() as { id: string };
    const second = fixture();
    expect(rejected(await upload(next.id, [second, { ...first, text: "changed" }]))).toBe(true);
    expect(await (await request("/v3/messages")).json()).toMatchObject({ messages: [expect.objectContaining({ id: `official.${first.id}` })] });
    const good = await upload(next.id, [second, first]);
    expect(JSON.parse(good.body.result.content[0].text)).toMatchObject({ imported: 1, duplicates: 1 });
  });
  it("accepts a late acknowledged sync once, without another delivery or new request", async () => {
    const { id, input } = await begin(); const message = fixture();
    await dispatch();
    await runInDurableObject(owner(), async (_, state) => state.storage.sql.exec("UPDATE history_sync_requests SET expires_at = ? WHERE id = ?", Date.now() - 1, id));
    expect(await (await request(`/v3/sync/${id}`)).json()).toMatchObject({ state: "delayed", deliveryAttempts: 1 });
    const coalesced = await (await request("/v3/sync", trigger())).json() as { id: string };
    expect(coalesced.id).toBe(id);
    expect((await rpc("tools/call", { name: "get_wearable_inbox", arguments: {} })).body.result.content[0].text).toContain('"state":"delayed"');
    const done = await upload(id, [message]);
    expect(JSON.parse(done.body.result.content[0].text)).toMatchObject({ state: "completed", imported: 1 });
    expect(rejected(await upload(id, [message]))).toBe(false);
    expect((await request("/v3/sync", input)).status).toBe(200);
    await dispatch(); expect(events).toHaveLength(1);
    expect((await (await request("/v3/messages")).json() as { messages: unknown[] }).messages).toHaveLength(1);
  });
  it("does not mistake device polling for the dot observing a history request", async () => {
    const { id } = await begin(); await dispatch();
    for (let index = 0; index < 4; index++) {
      const receipt = await (await request(`/v3/sync/${id}`)).json();
      expect(receipt).toMatchObject({ timing: { readAt: null }, historyImport: { startedAt: null, attempts: 0 } });
      await request("/v3/messages");
    }
    const before = Date.now();
    await rpc("tools/call", { name: "get_wearable_inbox", arguments: {} }, "fixture-mcp-key", { "X-MCP-Received-At": "1" });
    const observed = await (await request(`/v3/sync/${id}`)).json() as { timing: { readAt: number; mcpReceivedAt: number; mcpAuthorizedAt: number } };
    expect(observed.timing.readAt).toBeGreaterThanOrEqual(before);
    expect(observed.timing.mcpReceivedAt).toBeGreaterThanOrEqual(before);
    expect(observed.timing.mcpAuthorizedAt).toBeGreaterThanOrEqual(observed.timing.mcpReceivedAt);
    await rpc("tools/call", { name: "get_wearable_inbox", arguments: {} });
    expect((await (await request(`/v3/sync/${id}`)).json() as { timing: unknown }).timing).toEqual(observed.timing);
  });
  it("records direct history tool ingress without requiring an extra inbox read", async () => {
    const { id } = await begin();
    const before = Date.now(), imported = await upload(id, [fixture()]);
    const receipt = JSON.parse(imported.body.result.content[0].text);
    expect(receipt).toMatchObject({ state: "completed", historyImport: { attempts: 1, lastFailedAt: null, lastError: null } });
    expect(receipt.timing.mcpReceivedAt).toBeGreaterThanOrEqual(before);
    expect(receipt.historyImport.startedAt).toBeGreaterThanOrEqual(receipt.timing.readAt);
    expect(receipt.completedAt).toBeGreaterThanOrEqual(receipt.historyImport.startedAt);
  });
  it("records safe failed-import metadata while keeping text atomic and completed replay immutable", async () => {
    const { id } = await begin(), row = fixture();
    expect(rejected(await upload(id, [row, row]))).toBe(true);
    const failed = await (await request(`/v3/sync/${id}`)).json();
    expect(failed).toMatchObject({ state: "pending", historyImport: { attempts: 1, lastError: "invalid_params" } });
    expect(failed.historyImport.lastFailedAt).toBeGreaterThanOrEqual(failed.historyImport.startedAt);
    expect(await (await request("/v3/messages")).json()).toMatchObject({ messages: [] });
    const done = JSON.parse((await upload(id, [row])).body.result.content[0].text);
    expect(done.historyImport).toMatchObject({ attempts: 2, lastError: "invalid_params", startedAt: failed.historyImport.startedAt });
    expect(JSON.parse((await upload(id, [row])).body.result.content[0].text)).toEqual(done);
    expect(rejected(await upload(id, [{ ...row, text: "changed replay" }]))).toBe(true);
    expect(await (await request(`/v3/sync/${id}`)).json()).toEqual(done);
  });
  it("does not backfill historical timing or let unknown requests create diagnostic rows", async () => {
    const { id } = await begin();
    await runInDurableObject(owner(), async (_, state) => {
      for (const column of ["import_started_at", "import_attempts", "import_failed_at", "import_error"]) state.storage.sql.exec(`ALTER TABLE history_sync_requests DROP COLUMN ${column}`);
      new DotHistory(state.storage).initialize();
    });
    const original = await (await request(`/v3/sync/${id}`)).json();
    expect(original).toMatchObject({ timing: { readAt: null }, historyImport: { startedAt: null, attempts: 0, lastError: null } });
    expect(rejected(await upload(crypto.randomUUID(), [fixture()]))).toBe(true);
    expect(await (await request(`/v3/sync/${id}`)).json()).toEqual(original);
  });
  it("runs 24 virtual hours of sync, restart, late arrival, exact text and mirror deduplication (not real dot)", async () => {
    await request("/v2/status");
    const base = Date.now(), official: { id: string; role: "user" | "assistant"; text: string; sentAt: number }[] = [];
    const expectedIDs = new Set<string>();
    let casesWithLateArrival = 0, conflictRollbacks = 0, restarts = 0;
    for (let index = 0; index < 96; index++) {
      const createdAt = base + index * 900_000, nativeID = crypto.randomUUID(), syncID = crypto.randomUUID();
      const text = `隔离长测${index}：水獭🦦 e\u0301 / é`, answer = `fixture-only answer ${index} 🍁`;
      const originals = [{ id: crypto.randomUUID(), role: "user" as const, text: `官方隔离${index}🙂`, sentAt: createdAt - 2 },
        { id: crypto.randomUUID(), role: "assistant" as const, text: `mock official reply ${index}🦊`, sentAt: createdAt - 1 }];
      official.push(...originals);
      const batch = [...official.slice(-28), { id: crypto.randomUUID(), role: "assistant" as const,
        text: `来自手机／手表\n用户：${text}\ndot：${answer}\n同步编号：${nativeID}`, sentAt: createdAt + 1 }];
      await runInDurableObject(owner(), async (_, state) => {
        let clock = createdAt;
        const history = new DotHistory(state.storage, () => clock); history.initialize();
        state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state, reply, replied_at) VALUES (?, 'virtual-soak', ?, ?, 'fixture', 'replied', ?, ?)", nativeID, text, createdAt, answer, createdAt + 1);
        history.request({ id: syncID, createdAt }, "virtual-soak-sub");
        state.storage.sql.exec("INSERT INTO outbox VALUES (?, 'virtual-soak-sub', '{}', ?, 1, 'acknowledged', NULL)", syncID, clock);
        state.storage.sql.exec("INSERT INTO message_timings (id, accepted_at, dispatched_at, acknowledged_at) VALUES (?, ?, ?, ?)", syncID, clock, clock, clock + 1);
        if (index % 3 === 0) {
          clock += 600_000; casesWithLateArrival++;
          expect(history.status(syncID)).toMatchObject({ state: "delayed", deliveryAttempts: 1 });
          const coalesced = history.request({ id: crypto.randomUUID(), createdAt: clock }, "virtual-soak-sub");
          expect(coalesced.created).toBe(false); expect(coalesced.receipt.id).toBe(syncID);
        } else clock += 15_000;
        if (index > 0 && index % 10 === 0) {
          const extra = { ...originals[0], id: crypto.randomUUID() };
          expect(() => history.import({ request_id: syncID, room_id: authorizedDotRoom, messages: [extra, { ...official[0], text: "conflict" }], truncated: true }, "virtual-soak-sub")).toThrow();
          expect(state.storage.sql.exec("SELECT id FROM official_dot_messages WHERE id = ?", extra.id).toArray()).toEqual([]);
          conflictRollbacks++;
        }
        const payload = { request_id: syncID, room_id: authorizedDotRoom, messages: batch, truncated: index > 13 };
        const done = history.import(payload, "virtual-soak-sub");
        expect(done.state).toBe("completed"); expect(done.deliveryAttempts).toBe(1);
        expect(history.import(payload, "virtual-soak-sub")).toEqual(done);
        expect(done.messages!.length + done.hiddenMessageIDs!.length).toBeLessThanOrEqual(30);
        const stored = state.storage.sql.exec<{ text: string; reply: string }>("SELECT text, reply FROM messages WHERE id = ?", nativeID).one();
        expect(stored).toEqual({ text, reply: answer });
        expect(state.storage.sql.exec("SELECT id FROM official_dot_messages WHERE id = ? AND visible = 1", batch.at(-1)!.id).toArray()).toEqual([]);
      });
      for (const row of originals) expectedIDs.add("official." + row.id);
      expectedIDs.add(nativeID + ".user"); expectedIDs.add(nativeID + ".reply");
      if (index % 12 === 11) { await abortAllDurableObjects(); restarts++; }
    }
    await runInDurableObject(owner(), async (_, state) => {
      const history = new DotHistory(state.storage, () => base + 86_400_000); history.initialize();
      const seen = new Set<string>(); let cursor: string | undefined;
      do {
        const page = history.timeline(cursor);
        for (const row of page.messages) { expect(seen.has(row.id)).toBe(false); seen.add(row.id); }
        cursor = page.nextCursor ?? undefined;
      } while (cursor);
      expect(seen).toEqual(expectedIDs);
      expect(state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM history_sync_requests WHERE state = 'completed'").one().count).toBe(96);
      expect(state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM outbox WHERE state != 'answered'").one().count).toBe(0);
    });
    expect(events).toEqual([]);
    console.info(JSON.stringify({ fixtureOnly: true, virtualHours: 24, syncCycles: 96, casesWithLateArrival, conflictRollbacks, durableObjectRestarts: restarts,
      exactTimelineRecords: expectedIDs.size, realDotReplies: 0, elapsed24WallClockHours: false }));
  });
  it("rejects late imports after revocation, re-subscription or the recovery deadline", async () => {
    const { id } = await begin(); await dispatch();
    await runInDurableObject(owner(), async (_, state) => state.storage.sql.exec("UPDATE history_sync_requests SET expires_at = ? WHERE id = ?", Date.now() - 1, id));
    expect(await (await request(`/v3/sync/${id}`)).json()).toMatchObject({ state: "delayed" });
    expect((await rpc("events/unsubscribe", { name: eventName, arguments: { inbox: "wearable" }, delivery: { mode: "webhook", url: callback } })).body.error).toBeUndefined();
    await connect();
    expect(rejected(await upload(id, [fixture()]))).toBe(true);
    await runInDurableObject(owner(), async (_, state) => {
      state.storage.sql.exec("UPDATE history_sync_requests SET created_at = ? WHERE id = ?", Date.now() - 61_000, id);
    });
    const next = await (await request("/v3/sync", trigger())).json() as { id: string };
    await dispatch();
    await runInDurableObject(owner(), async (_, state) => state.storage.sql.exec("UPDATE history_sync_requests SET expires_at = ?, recover_until = ? WHERE id = ?", Date.now() - 2, Date.now() - 1, next.id));
    expect(rejected(await upload(next.id, [fixture()]))).toBe(true);
    expect(await (await request(`/v3/sync/${next.id}`)).json()).toMatchObject({ state: "expired" });
  });
  it("never revives old expired rows without an explicit recovery window", async () => {
    const { id } = await begin(); await dispatch();
    await runInDurableObject(owner(), async (_, state) => state.storage.sql.exec("UPDATE history_sync_requests SET expires_at = ?, recover_until = NULL WHERE id = ?", Date.now() - 1, id));
    expect(rejected(await upload(id, [fixture()]))).toBe(true);
  });
  it("does not duplicate verified companion mirrors, but preserves spoofed mirror text", async () => {
    const { id } = await begin(); const input = command("手机原文🙂");
    await send(input); await reply(input.id, "同一回复🍁");
    const mirror = fixture(crypto.randomUUID(), "assistant", `来自手机／手表\n用户：${input.text}\ndot：同一回复🍁\n同步编号：${input.id}`);
    const spoof = { ...mirror, id: crypto.randomUUID(), text: mirror.text.replace("同一回复", "不相同") };
    const result = await upload(id, [mirror, spoof]);
    expect(JSON.parse(result.body.result.content[0].text)).toMatchObject({ imported: 1, mirrored: 1 });
    const timeline = await (await request("/v3/messages")).json() as { messages: { id: string }[] };
    expect(timeline.messages.map(m => m.id)).toEqual(expect.arrayContaining([input.id + ".user", input.id + ".reply", "official." + spoof.id]));
    expect(timeline.messages).toHaveLength(3);
  });
  it("recognizes mirror field layout changes without normalizing original text or hiding independent official replies", async () => {
    const { id } = await begin(); const input = command("首行🙂\n第二行  空格保留");
    const answer = "答复第一段\n\ndot：内部标签🍁";
    await send(input); await reply(input.id, answer);
    const fields = ["来自手机／手表", `用户：${input.text}`, `dot：${answer}`, `同步编号：${input.id}`];
    const mirrors = [" ", "\n", "\r\n\t", "\n\n"].map(separator => fixture(crypto.randomUUID(), "assistant", fields.join(separator)));
    const plain = fixture(crypto.randomUUID(), "assistant", answer);
    const changedInput = fixture(crypto.randomUUID(), "assistant", mirrors[0].text.replace("  空格", " 空格"));
    const appended = fixture(crypto.randomUUID(), "assistant", mirrors[0].text + " extra text");
    const userLookalike = fixture(crypto.randomUUID(), "user", mirrors[0].text);
    const preserved = [plain, changedInput, appended, userLookalike];
    const result = await upload(id, [...mirrors, ...preserved]);
    expect(JSON.parse(result.body.result.content[0].text)).toMatchObject({ imported: 4, mirrored: 4, duplicates: 0 });
    const timeline = await (await request("/v3/messages")).json() as { messages: { id: string; text: string }[] };
    expect(timeline.messages).toHaveLength(6);
    for (const item of preserved) expect(timeline.messages).toContainEqual(expect.objectContaining({ id: "official." + item.id, text: item.text }));
    for (const item of mirrors) expect(timeline.messages.some(row => row.id === "official." + item.id)).toBe(false);
  });
  it("repairs only verified already-imported mirrors and rolls back repairs when any supplied history conflicts", async () => {
    const { id } = await begin(); const input = command("旧导入原文🦦");
    await send(input); await reply(input.id, "旧导入回复🍁");
    const flat = fixture(crypto.randomUUID(), "assistant", `来自手机／手表 用户：${input.text} dot：旧导入回复🍁 同步编号：${input.id}`);
    const spoof = { ...flat, id: crypto.randomUUID(), text: flat.text.replace("旧导入回复", "不相同回复") };
    await runInDurableObject(owner(), async (_, state) => {
      for (const row of [flat, spoof]) state.storage.sql.exec("INSERT INTO official_dot_messages VALUES (?, ?, ?, ?, 1)", row.id, row.role, row.text, row.sentAt);
    });
    expect(rejected(await upload(id, [flat, { ...spoof, text: "conflicting immutable text" }]))).toBe(true);
    await runInDurableObject(owner(), async (_, state) => {
      expect(state.storage.sql.exec<{ visible: number }>("SELECT visible FROM official_dot_messages WHERE id = ?", flat.id).one().visible).toBe(1);
    });
    const result = await upload(id, [flat, spoof]);
    const receipt = JSON.parse(result.body.result.content[0].text);
    expect(receipt).toMatchObject({ imported: 0, mirrored: 1, duplicates: 1 });
    const replay = await upload(id, [flat, spoof]);
    expect(JSON.parse(replay.body.result.content[0].text)).toEqual(receipt);
    const timeline = await (await request("/v3/messages")).json() as { messages: { id: string }[] };
    expect(timeline.messages.some(row => row.id === "official." + flat.id)).toBe(false);
    expect(timeline.messages.some(row => row.id === "official." + spoof.id)).toBe(true);
  });
  it("merges pagination with tied timestamps without missing or duplicating original records", async () => {
    const { id } = await begin();
    const messages = Array.from({ length: 30 }, () => fixture());
    await upload(id, messages);
    const input = command("extra"); await send(input); await reply(input.id, "extra reply");
    const page1 = await (await request("/v3/messages")).json() as { messages: { id: string }[]; nextCursor: string };
    const page2 = await (await request(`/v3/messages?cursor=${encodeURIComponent(page1.nextCursor)}`)).json() as { messages: { id: string }[]; nextCursor: string | null };
    const all = [...page1.messages, ...page2.messages];
    expect(all).toHaveLength(32); expect(new Set(all.map(m => m.id)).size).toBe(32); expect(page2.nextCursor).toBeNull();
    expect((await request("/v3/messages?cursor=bad")).status).toBe(400);
  });
  it("rejects duplicate IDs, oversized batches and invalid Unicode without partial import", async () => {
    const { id } = await begin(), m = fixture();
    for (const batch of [[m, m], Array.from({ length: 31 }, () => fixture()), [{ ...m, text: "\ud800" }], Array.from({ length: 4 }, () => fixture(crypto.randomUUID(), "user", "中".repeat(5000)))]) {
      expect(rejected(await upload(id, batch))).toBe(true);
    }
    expect(await (await request("/v3/messages")).json()).toMatchObject({ messages: [] });
  });
});

describe("official MCP Events local prototype (mock receiver, no real dot)", () => {
  it("cannot be served at a public hostname, even with the fixture key", async () => {
    expect((await request("/v2/status", undefined, "fixture-device-key", {}, "https://public.example")).status).toBe(403);
  });
  it("enforces different credentials for device reads and model writes", async () => {
    expect((await request("/v2/status", undefined, "fixture-mcp-key")).status).toBe(401);
    expect((await rpc("events/list", {}, "fixture-device-key")).status).toBe(401);
    expect(events).toHaveLength(0); expect(verifications).toBe(0);
  });
  it("rejects a foreign browser Origin and forged Host", async () => {
    expect((await request("/v2/status", undefined, "fixture-device-key", { Origin: "https://evil.example" })).status).toBe(403);
    expect((await request("/v2/status", undefined, "fixture-device-key", { Host: "evil.example" })).status).toBe(403);
  });
  it("discovers events over actual SDK MCP 2.0 HTTP transport", async () => {
    const probe = await rpc("server/discover");
    expect(probe.status).toBe(200);
    expect(probe.body.result).toMatchObject({ supportedVersions: ["2026-07-28"], capabilities: { events: {}, tools: {} } });
    const catalog = await rpc("events/list");
    expect(catalog.body.result.events[0]).toMatchObject({ name: eventName, delivery: ["webhook"] });
  });
  it("supports authenticated stateless legacy plugin discovery with the same bounded catalog", async () => {
    const legacy = async (method: string, params: Record<string, unknown> = {}, key = "fixture-mcp-key") => {
      const response = await request("/mcp", { jsonrpc: "2.0", id: 42, method, params }, key,
        { Accept: "application/json, text/event-stream", "MCP-Protocol-Version": "2025-11-25" });
      const text = await response.text();
      const data = response.headers.get("Content-Type")?.includes("text/event-stream")
        ? text.split("\n").find(line => line.startsWith("data: "))?.slice(6) : text;
      return { status: response.status, body: JSON.parse(data!) };
    };
    const init = await legacy("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "plugin-discovery-fixture", version: "1" } });
    expect(init.status).toBe(200);
    expect(init.body.result).toMatchObject({ protocolVersion: "2025-11-25", capabilities: { tools: {}, events: {} } });
    const catalog = await legacy("tools/list");
    expect(catalog.body.result.tools.map((t: { name: string }) => t.name).sort()).toEqual([
      "get_wearable_inbox", "read_wearable_conversation", "read_wearable_thread", "reply_to_wearable_message", "sync_your_dot_history",
    ]);
    expect((await request("/mcp", { jsonrpc: "2.0", id: 42, method: "tools/list" }, "fixture-device-key")).status).toBe(401);
    expect((await legacy("tools/call", { name: "approve_request", arguments: {} })).body.error).toBeDefined();
    expect((await rpc("events/list")).body.result.events[0].name).toBe(eventName);
  });
  it("exposes only bounded messaging/history tools and no approvals/command execution", async () => {
    const tools = await rpc("tools/list");
    expect(tools.body.result.tools.map((t: { name: string }) => t.name).sort()).toEqual(["get_wearable_inbox", "read_wearable_conversation", "read_wearable_thread", "reply_to_wearable_message", "sync_your_dot_history"]);
    expect((await rpc("tools/call", { name: "approve_request", arguments: {} })).body.error).toBeDefined();
    expect((await request("/v2/status")).status).toBe(200);
    expect(await (await request("/v2/status")).json()).toMatchObject({ capabilities: { approvals: false, runtimeStatus: false }, realDotVerified: false });
  });
  it("does not accept device messages before the dot subscribes", async () => {
    const response = await send(command()); expect(response.status).toBe(503);
    expect(events).toHaveLength(0);
  });
  it("verifies a signed single-use challenge before activation", async () => {
    const sub = await connect(); expect(sub.body.error).toBeUndefined(); expect(verifications).toBe(1);
    expect(await (await request("/v2/status")).json()).toMatchObject({ subscribed: true });
    const again = await connect(); expect(again.body.result.id).toBe(sub.body.result.id); expect(verifications).toBe(1);
  });
  it("rejects invalid filters and invalid signing keys", async () => {
    expect((await rpc("events/subscribe", { ...subscription(), arguments: { inbox: "other" } })).body.error).toBeDefined();
    expect((await rpc("events/subscribe", subscription(callback, "whsec_dGlueQ=="))).body.error).toMatchObject({ code: -32602 });
    expect(verifications).toBe(0);
  });
  it.each(["http://mcp-callback.invalid/events/x", "https://127.0.0.1/events/x", "https://169.254.169.254/events/x", "https://user:pass@mcp-callback.invalid/events/x", "https://evil.example/events/x", "https://mcp-callback.invalid:8443/events/x", "https://mcp-callback.invalid/events/x#secret"])("blocks unsafe or unapproved callback %s without network access", async url => {
    const result = await rpc("events/subscribe", subscription(url));
    expect(result.body.error).toMatchObject({ code: -32015 }); expect(verifications).toBe(0);
  });
  it("does not activate if challenge verification fails", async () => {
    badChallenge = true;
    expect((await connect()).body.error).toMatchObject({ code: -32015 });
    expect(await (await request("/v2/status")).json()).toMatchObject({ subscribed: false });
    const diagnostic = await owner().execute({ kind: "diagnostics" });
    expect(diagnostic).toMatchObject({ ok: true, value: { subscription: { stage: "failed", code: "challenge_failed" }, subscriptionIntents: 1, subscribed: false } });
    expect(JSON.stringify(diagnostic)).not.toContain(secret);
    expect(JSON.stringify(diagnostic)).not.toContain(callback);
  });
  it("stores exact Unicode and delivers once with a stable event ID", async () => {
    await connect(); const input = command("中文跟进收发一致，测试结束🙂\n<@UOTHER> & 3 < 5");
    expect(await (await send(input)).json()).toMatchObject({ id: input.id, state: "queued", text: input.text });
    await dispatch(); expect(events).toHaveLength(1);
    expect(events[0]).toMatchObject({ eventId: input.id, data: { text: input.text, message_id: input.id, thread_id: input.id }, cursor: null });
    expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ state: "delivered" });
    expect(JSON.stringify(events[0])).not.toContain("instructions");
  });
  it("does not pretend a 202 acknowledgement is an assistant reply", async () => {
    await connect(); const input = command(); await send(input); await dispatch();
    const receipt = await (await request(`/v2/receipts/${input.id}`)).json() as Record<string, unknown>;
    expect(receipt.state).toBe("delivered"); expect(receipt.reply).toBeUndefined();
  });
  it("records callback and MCP read timing separately from native history reads", async () => {
    await connect(); const input = command("计时🙂"); await send(input);
    const queued = await (await request(`/v2/receipts/${input.id}`)).json() as any;
    expect(queued.timing.acceptedAt).toBeGreaterThanOrEqual(input.createdAt);
    // The real local alarm may dispatch before the immediate receipt read.
    // It must not count a device read as the model reading the message.
    if (queued.timing.dispatchedAt !== null) expect(queued.timing.dispatchedAt).toBeGreaterThanOrEqual(queued.timing.acceptedAt);
    expect(queued.timing.readAt).toBeNull();
    await dispatch();
    const delivered = await (await request(`/v2/receipts/${input.id}`)).json() as any;
    expect(delivered.timing.attempts).toBe(1); expect(delivered.timing.lastStatus).toBe(202);
    expect(delivered.timing.acknowledgedAt).toBeGreaterThanOrEqual(delivered.timing.dispatchedAt);
    const native = await (await request(`/v2/threads/${input.id}/messages`)).json() as any;
    expect(native.messages[0].timing.readAt).toBeNull();
    await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: input.id } });
    const read = await (await request(`/v2/receipts/${input.id}`)).json() as any;
    expect(read.timing.readAt).toBeGreaterThanOrEqual(delivered.timing.acknowledgedAt);
    await reply(input.id, "计时回复🙂");
    const replied = await (await request(`/v2/receipts/${input.id}`)).json() as any;
    expect(replied.repliedAt).toBeGreaterThanOrEqual(read.timing.readAt);
    expect(JSON.stringify(replied.timing)).not.toContain(callback);
    expect(JSON.stringify(replied.timing)).not.toContain(secret);
  });
  it("keeps old read-but-unanswered inputs visible to the next MCP read without redelivery", async () => {
    await connect();
    const old = command("旧问题🙂"); await send(old); await dispatch();
    await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: old.id } });
    const next = command("接续问题🍁", old.id); await send(next); await dispatch();
    const other = command("另一个线程"); await send(other); await dispatch();
    const before = events.length;
    const read = await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: old.id } });
    const body = JSON.parse(read.body.result.content[0].text);
    expect(body.replyRequired).toEqual([old.id, next.id]);
    expect(body.replyRequired).not.toContain(other.id);
    expect(body.deliveryInstructions).toContain("readAt");
    expect(body.messages[0].timing.readAt).not.toBeNull();
    await reply(old.id, "旧问题回复");
    const again = await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: old.id } });
    expect(JSON.parse(again.body.result.content[0].text).replyRequired).toEqual([next.id]);
    const native = await (await request(`/v2/threads/${old.id}/messages`)).json() as any;
    expect(native.replyRequired).toBeUndefined();
    expect(native.deliveryInstructions).toBeUndefined();
    expect(events).toHaveLength(before);
  });
  it("bounds explicit thread reads and leaves older inputs unread", async () => {
    await connect(); const root = command("较早原文🦦"); await send(root);
    const ids = [root.id];
    for (let i = 1; i < 32; i++) ids.push(crypto.randomUUID());
    await runInDurableObject(owner(), async (_, state) => {
      for (let i = 1; i < ids.length; i++) {
        state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state) VALUES (?, ?, ?, ?, 'fixture', 'delivered')", ids[i], root.id, `原文${i}🍁`, Date.now());
        state.storage.sql.exec("INSERT INTO message_timings (id, accepted_at) VALUES (?, ?)", ids[i], Date.now());
      }
    });
    const read = await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: root.id, limit: 30 } });
    const data = JSON.parse(read.body.result.content[0].text);
    expect(data.messages.map((row: { id: string }) => row.id)).toEqual(ids.slice(2));
    expect(data.truncated).toBe(true); expect(data.selection).toEqual({ limit: 30 });
    expect(data.replyRequired).toEqual(ids.slice(2));
    for (const id of ids.slice(0, 2)) {
      const receipt = await (await request(`/v2/receipts/${id}`)).json() as any;
      expect(receipt.timing.readAt).toBeNull();
    }
    expect(data.messages.every((row: { timing: { readAt: number | null } }) => row.timing.readAt !== null)).toBe(true);
  });
  it("recovers only one selected input without reading neighbours or sync work", async () => {
    await connect(); const selected = command("只读这一条🙂"); await send(selected);
    const neighbour = command("不应读取的邻近消息", selected.id); await send(neighbour);
    const other = command("不应读取的另一线程"); await send(other);
    await request("/v3/sync", { id: crypto.randomUUID(), createdAt: Date.now() });
    const read = await rpc("tools/call", { name: "read_wearable_thread", arguments: {
      thread_id: selected.id.toUpperCase(), message_id: selected.id.toUpperCase(), limit: 30,
    } });
    const data = JSON.parse(read.body.result.content[0].text);
    expect(data.messages).toHaveLength(1); expect(data.messages[0].text).toBe(selected.text);
    expect(data.selection).toEqual({ message_id: selected.id });
    expect(data.replyRequired).toEqual([selected.id]); expect(data.syncRequests).toBeUndefined();
    expect(data.truncated).toBe(false);
    for (const id of [neighbour.id, other.id]) {
      expect(((await (await request(`/v2/receipts/${id}`)).json()) as any).timing.readAt).toBeNull();
    }
    await reply(selected.id, "真实替身回复🍁");
    const again = await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: selected.id, message_id: selected.id } });
    const answered = JSON.parse(again.body.result.content[0].text);
    expect(answered.messages[0].reply).toBe("真实替身回复🍁"); expect(answered.replyRequired).toEqual([]);
  });
  it("never falls back to full history for a missing or foreign selected input", async () => {
    await connect(); const a = command("线程一"); const b = command("线程二"); await send(a); await send(b);
    for (const message_id of [b.id, crypto.randomUUID()]) {
      const read = await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: a.id, message_id } });
      expect(read.body.error || read.body.result?.isError).toBeTruthy();
      expect(JSON.stringify(read.body)).not.toContain(a.text);
    }
    expect(((await (await request(`/v2/receipts/${a.id}`)).json()) as any).timing.readAt).toBeNull();
  });
  it.each([0, 31, -1, 1.5, "30"])("rejects invalid explicit thread limit %s before reading", async limit => {
    await connect(); const input = command(); await send(input);
    const read = await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: input.id, limit } });
    expect(read.body.error || read.body.result?.isError).toBeTruthy();
    expect(((await (await request(`/v2/receipts/${input.id}`)).json()) as any).timing.readAt).toBeNull();
  });
  it("records trusted MCP ingress/auth timing once, ignoring client timestamp headers", async () => {
    await connect(); const input = command("入口计时🦦"); await send(input); await dispatch();
    const native = await (await request(`/v2/threads/${input.id}`)).json() as any;
    expect(native.messages[0].timing.mcpReceivedAt).toBeUndefined();
    const before = Date.now();
    const read = await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: input.id } }, "fixture-mcp-key",
      { "X-MCP-Received-At": "1", "X-MCP-Authorized-At": "2" });
    const timing = JSON.parse(read.body.result.content[0].text).messages[0].timing;
    expect(timing.mcpReceivedAt).toBeGreaterThanOrEqual(before);
    expect(timing.mcpAuthorizedAt).toBeGreaterThanOrEqual(timing.mcpReceivedAt);
    expect(timing.readAt).toBeGreaterThanOrEqual(timing.mcpAuthorizedAt);
    await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: input.id } });
    expect((await (await request(`/v2/receipts/${input.id}`)).json() as any).timing).toEqual(timing);
    const invalid = await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: input.id, mcpReceivedAt: 1 } });
    expect(invalid.body.error || invalid.body.result?.isError).toBeTruthy();
  });
  it("never invents ingress timestamps for a legacy first read", async () => {
    await connect(); const input = command("旧计时保留"); await send(input); await dispatch();
    const legacy = Date.now() - 1000;
    await runInDurableObject(owner(), async (_, state) => {
      state.storage.sql.exec("UPDATE message_timings SET read_at = ? WHERE id = ?", legacy, input.id);
    });
    await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: input.id } });
    const timing = (await (await request(`/v2/receipts/${input.id}`)).json() as any).timing;
    expect(timing.readAt).toBe(legacy);
    expect(timing.mcpReceivedAt).toBeUndefined(); expect(timing.mcpAuthorizedAt).toBeUndefined();
  });
  it("adds ingress columns to retained legacy timings after restart without changing receipts", async () => {
    await connect(); const input = command("兼容迁移🍁"); await send(input); await dispatch();
    const before = await (await request(`/v2/receipts/${input.id}`)).json();
    await runInDurableObject(owner(), async (_, state) => {
      // Only this isolated fixture recreates the pre-instrumentation schema.
      state.storage.sql.exec("ALTER TABLE message_timings DROP COLUMN mcp_received_at");
      state.storage.sql.exec("ALTER TABLE message_timings DROP COLUMN mcp_authorized_at");
    });
    await abortAllDurableObjects();
    expect(await (await request(`/v2/receipts/${input.id}`)).json()).toEqual(before);
    await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: input.id } });
    const after = (await (await request(`/v2/receipts/${input.id}`)).json() as any).timing;
    expect(after.mcpReceivedAt).toBeTypeOf('number'); expect(after.mcpAuthorizedAt).toBeTypeOf('number');
    expect(events).toHaveLength(1);
  });
  it("rejects malformed, reversed or future trusted timing without altering the read event", () => {
    expect(validRequestTiming({ receivedAt: 10, authorizedAt: 20 }, 30)).toEqual({ receivedAt: 10, authorizedAt: 20 });
    for (const value of [undefined, { receivedAt: -1, authorizedAt: 20 }, { receivedAt: NaN, authorizedAt: 20 },
      { receivedAt: 30, authorizedAt: 20 }, { receivedAt: 10, authorizedAt: 31 }, { receivedAt: 1.5, authorizedAt: 20 }]) {
      expect(validRequestTiming(value, 30)).toBeUndefined();
    }
  });
  it("legacy native thread reads never masquerade as dot activity or consume pending work", async () => {
    await connect(); const input = command("原生历史不是 dot 已读🦦"); await send(input); await dispatch();
    for (let i = 0; i < 3; i++) {
      const page = await (await request(`/v2/threads/${input.id}`)).json() as any;
      expect(page.messages[0].timing.readAt).toBeNull();
      expect(page.replyRequired).toBeUndefined();
      expect(page.syncRequests).toBeUndefined();
    }
    const diagnostic = await owner().execute({ kind: "diagnostics" });
    expect(diagnostic.ok).toBe(true);
    expect(JSON.stringify(diagnostic)).not.toContain("tool:read_wearable_thread");
    const mcp = await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: input.id } });
    const read = JSON.parse(mcp.body.result.content[0].text);
    expect(read.replyRequired).toEqual([input.id]);
    expect(read.messages[0].timing.readAt).not.toBeNull();
    expect(events).toHaveLength(1);
  });
  it("exposes delayed history work to the next authenticated thread read, not native polling", async () => {
    await connect(); const input = command(); await send(input); await dispatch();
    const sync = { id: crypto.randomUUID(), createdAt: Date.now() };
    await request("/v3/sync", sync); await dispatch();
    await runInDurableObject(owner(), async (_instance, state) => {
      state.storage.sql.exec("UPDATE history_sync_requests SET expires_at = ? WHERE id = ?", Date.now() - 1, sync.id);
    });
    const read = await rpc("tools/call", { name: "read_wearable_thread", arguments: { thread_id: input.id } });
    expect(JSON.parse(read.body.result.content[0].text).syncRequests).toMatchObject([{ id: sync.id, state: "delayed" }]);
    const native = await (await request("/v2/messages")).json() as any;
    expect(native.syncRequests).toBeUndefined();
  });
  it("lists shared conversations with Unicode titles, stable pagination and no duplicates", async () => {
    await connect();
    await runInDurableObject(owner(), async (_instance, state) => {
      for (let i = 0; i < 23; i++) {
        const id = crypto.randomUUID();
        state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state) VALUES (?, ?, ?, ?, 'fixture', 'replied')", id, id, `中文🙂\n对话 ${i}`, 1000 + i);
      }
    });
    const first = await (await request('/v2/threads')).json() as any;
    expect(first.threads).toHaveLength(20); expect(first.threads[0].title).toBe("中文🙂 对话 22");
    const next = await (await request(`/v2/threads?cursor=${first.nextCursor}`)).json() as any;
    expect(next.threads).toHaveLength(3); expect(next.nextCursor).toBeNull();
    expect(new Set([...first.threads, ...next.threads].map(t => t.id)).size).toBe(23);
    expect((await request('/v2/threads?cursor=invalid')).status).toBe(400);
    expect((await request('/v2/threads', undefined, 'fixture-mcp-key')).status).toBe(401);
  });
  it("maintains thread summaries atomically and pages without scanning message history", async () => {
    await connect();
    await runInDurableObject(owner(), async (_instance, state) => {
      const thread = crypto.randomUUID();
      for (let index = 0; index < 200; index++) {
        state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state) VALUES (?, ?, ?, ?, 'fixture', 'queued')", crypto.randomUUID(), thread, `原文🍁 ${index}`, 1000 + index);
      }
      const rows = state.storage.sql.exec<{ id: string; title: string; updatedAt: number }>(threadSummaryPageQuery, Number.MAX_SAFE_INTEGER, "");
      expect(rows.toArray()).toEqual([{ id: thread, title: "原文🍁 0", updatedAt: 1199 }]);
      expect(rows.rowsRead).toBeLessThan(25);
      state.storage.sql.exec("UPDATE messages SET replied_at = 9999 WHERE sequence = 1");
      expect(state.storage.sql.exec<{ updated_at: number }>("SELECT updated_at FROM thread_summaries WHERE thread_id = ?", thread).one().updated_at).toBe(9999);
      expect(() => state.storage.transactionSync(() => {
        state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state) VALUES (?, ?, 'rollback', 20000, 'fixture', 'queued')", crypto.randomUUID(), thread);
        throw new Error("fixture rollback");
      })).toThrow();
      expect(state.storage.sql.exec<{ updated_at: number }>("SELECT updated_at FROM thread_summaries WHERE thread_id = ?", thread).one().updated_at).toBe(9999);
    });
  });
  it("backfills old thread summaries once while preserving Unicode history", async () => {
    await connect();
    await runInDurableObject(owner(), async (_instance, state) => {
      const thread = crypto.randomUUID();
      state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state, reply, replied_at) VALUES (?, ?, '旧记录🦦', 1000, 'fixture', 'replied', '回复🍁', 2000)", crypto.randomUUID(), thread);
      state.storage.sql.exec("DELETE FROM thread_summaries");
      state.storage.sql.exec("DELETE FROM thread_summary_migrations WHERE version = 1");
      initializeThreadSummaries(state.storage);
      expect(state.storage.sql.exec(threadSummaryPageQuery, Number.MAX_SAFE_INTEGER, "").toArray()).toEqual([{ id: thread, title: "旧记录🦦", updatedAt: 2000 }]);
      state.storage.sql.exec("UPDATE thread_summaries SET title = 'migration already done'");
      initializeThreadSummaries(state.storage);
      expect(state.storage.sql.exec<{ title: string }>("SELECT title FROM thread_summaries").one().title).toBe("migration already done");
      expect(state.storage.sql.exec<{ reply: string }>("SELECT reply FROM messages").one().reply).toBe("回复🍁");
    });
  });
  it("shares one server-selected thread across independent devices without rewriting old history", async () => {
    await connect();
    const legacy = command("旧记录🙂"); await send(legacy);
    const phone = { ...command("手机🙂"), shared: true };
    const watch = { ...command("手表跟进🙂"), shared: true };
    const a = await (await send(phone)).json() as any;
    const b = await (await send(watch)).json() as any;
    expect(a.thread).toBe(phone.id); expect(b.thread).toBe(phone.id);
    expect((await (await send(watch)).json() as any).thread).toBe(phone.id);
    const timeline = await (await request('/v2/messages')).json() as any;
    expect(timeline.messages.map(m => m.text)).toEqual([legacy.text, phone.text, watch.text]);
    expect(timeline.messages[0].thread).toBe(legacy.id);
    expect((await request('/v2/messages', undefined, 'wrong')).status).toBe(401);
    expect(timeline.messages.every(m => m.timing.readAt === null)).toBe(true);
    await rpc('tools/call', { name: 'read_wearable_conversation', arguments: {} });
    const read = await (await request(`/v2/receipts/${watch.id}`)).json() as any;
    expect(read.timing.readAt).not.toBeNull();
  });
  it("paginates the unified timeline across legacy device threads without loss", async () => {
    await runInDurableObject(owner(), async (_instance, state) => {
      for (let i = 0; i < 35; i++) {
        const id = crypto.randomUUID();
        state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state) VALUES (?, ?, ?, ?, 'fixture', 'delivered')", id, id, `消息 ${i}`, 1000 + i);
      }
    });
    const recent = await (await request('/v2/messages')).json() as any;
    const older = await (await request(`/v2/messages?cursor=${recent.nextCursor}`)).json() as any;
    expect(recent.messages).toHaveLength(30); expect(older.messages).toHaveLength(5);
    expect(new Set([...older.messages, ...recent.messages].map(m => m.id)).size).toBe(35);
    expect(older.nextCursor).toBeNull();
    expect((await request('/v2/messages?cursor=0')).status).toBe(400);
  });
  it("paginates native history without hiding latest replies or treating UUIDs as timestamps", async () => {
    const root = crypto.randomUUID();
    await runInDurableObject(owner(), async (_instance, state) => {
      for (let i = 0; i < 35; i++) {
        state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state, reply, replied_at) VALUES (?, ?, ?, ?, 'fixture', 'replied', ?, ?)", crypto.randomUUID(), root, `消息 ${i}`, 1000 + i, `回复 ${i}`, 2000 + i);
      }
    });
    const latest = await (await request(`/v2/threads/${root}/messages`)).json() as any;
    expect(latest.messages).toHaveLength(30); expect(latest.messages[0].text).toBe('消息 5'); expect(latest.messages[29].reply).toBe('回复 34');
    const older = await (await request(`/v2/threads/${root}/messages?cursor=${latest.nextCursor}`)).json() as any;
    expect(older.messages).toHaveLength(5); expect(older.messages[0].text).toBe('消息 0'); expect(older.nextCursor).toBeNull();
    expect(new Set([...older.messages, ...latest.messages].map(m => m.id)).size).toBe(35);
    expect((await request(`/v2/threads/${root}/messages?cursor=-1`)).status).toBe(400);
  });
  it("deduplicates concurrent sends and detects changed request contents", async () => {
    await connect(); const input = command(); await Promise.all([send(input), send(input)]); await send(input); await dispatch();
    expect(events).toHaveLength(1);
    expect((await send({ ...input, text: "changed" })).status).toBe(409);
  });
  it("treats uppercase and lowercase UUIDs as the same command and conversation", async () => {
    await connect(); const input = { ...command(), id: "deadbeef-1234-4abc-8def-0123456789ab" };
    await send({ ...input, id: input.id.toUpperCase() }); await send(input); await dispatch();
    expect(events).toHaveLength(1); await reply(input.id.toUpperCase(), "UUID 一致🙂");
    expect(await (await request(`/v2/receipts/${input.id.toUpperCase()}`)).json()).toMatchObject({ id: input.id, reply: "UUID 一致🙂" });
    const followup = command("继续", input.id.toUpperCase()); await send(followup); await dispatch();
    const history = await (await request(`/v2/threads/${input.id.toUpperCase()}`)).json() as { messages: { thread: string }[] };
    expect(history.messages).toHaveLength(2); expect(history.messages.every(m => m.thread === input.id)).toBe(true);
  });
  it.each(["\ud800", "\udfff"])("rejects malformed Unicode without changing command or reply text", async malformed => {
    await connect(); expect((await send(command(`原文${malformed}`))).status).toBe(400);
    const input = command(); await send(input);
    expect((await reply(input.id, `回复${malformed}`)).body.result.isError).toBe(true);
    expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ text: input.text });
  });
  it("survives a Durable Object restart with receipt and pending delivery intact", async () => {
    await connect(); status = 503; const input = command(); await send(input); await abortAllDurableObjects();
    expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ state: "queued" });
    status = 202; await dispatch(); const acceptedCount = events.length;
    await abortAllDurableObjects(); await send(input); await dispatch(); expect(events).toHaveLength(acceptedCount);
    expect(new Set(events.map(e => e.eventId))).toEqual(new Set([input.id]));
  });
  it("retries transient failures with the same event identity, bounded to five attempts", async () => {
    await connect(); const input = command(); await send(input); status = 503;
    for (let i = 0; i < 5; i++) await dispatch();
    expect(events).toHaveLength(5); expect(new Set(events.map(e => e.eventId)).size).toBe(1);
    expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ state: "delivery_failed" });
    await dispatch(); expect(events).toHaveLength(5);
  });
  it.each([410, 413, 302, 403])("does not follow redirects or retry terminal callback status %s", async code => {
    await connect(); const input = command(); await send(input); status = code; await dispatch(); await dispatch();
    expect(events).toHaveLength(1);
    expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ state: "delivery_failed" });
  });
  it("returns immutable idempotent replies without generating more events", async () => {
    await connect(); const input = command(); await send(input); await dispatch();
    expect((await reply(input.id, "测试回复🙂")).body.error).toBeUndefined();
    expect((await reply(input.id, "测试回复🙂")).body.error).toBeUndefined();
    expect((await reply(input.id, "different")).body.result.isError).toBe(true);
    await dispatch(); expect(events).toHaveLength(1);
    expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ state: "replied", reply: "测试回复🙂" });
  });
  it("rolls back a reply if cancelling its delivery job fails, then accepts an identical retry", async () => {
    await connect(); const input = command(); await send(input); await dispatch();
    await runInDurableObject(owner(), async (_, state) => {
      state.storage.sql.exec("CREATE TRIGGER reject_fixture_answer BEFORE UPDATE ON outbox WHEN NEW.state = 'answered' BEGIN SELECT RAISE(ABORT, 'fixture_reply_failure'); END");
    });
    expect((await reply(input.id, "原文回复🙂")).body.result.isError).toBe(true);
    const failed = await (await request(`/v2/receipts/${input.id}`)).json() as { state: string; reply?: string };
    expect(failed.state).toBe("delivered"); expect(failed.reply).toBeUndefined();
    await runInDurableObject(owner(), async (_, state) => state.storage.sql.exec("DROP TRIGGER reject_fixture_answer"));
    expect((await reply(input.id, "原文回复🙂")).body.result.isError).not.toBe(true);
    expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ state: "replied", reply: "原文回复🙂" });
    await dispatch(); expect(events).toHaveLength(1);
  });
  it("does not overwrite a reply that arrives before callback acknowledgement", async () => {
    await connect(); const input = command(); await send(input);
    receiverHook = async event => { await owner().execute({ kind: "reply", input: { message_id: event.data.message_id, text: "fast reply" } }); };
    await dispatch(); expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ state: "replied", reply: "fast reply" });
  });
  it("stops retrying if the reply arrived but callback acknowledgement failed", async () => {
    await connect(); const input = command(); await send(input); status = 503;
    receiverHook = async event => { await owner().execute({ kind: "reply", input: { message_id: event.data.message_id, text: "reply preserved" } }); };
    await dispatch(); await dispatch(); expect(events).toHaveLength(1);
    expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ state: "replied", reply: "reply preserved" });
  });
  it("does not deliver an answered message from a stale multi-message alarm batch", async () => {
    const subscription = await connect(); const first = command("第一条"); const second = command("第二条");
    await runInDurableObject(owner(), async (_instance, state) => {
      // Seed one due batch without scheduling native alarms between inserts.
      // The dispatch/reply race below still uses the actual inbox implementation.
      for (const input of [first, second]) {
        state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state) VALUES (?, ?, ?, ?, 'fixture', 'queued')", input.id, input.id, input.text, input.createdAt);
        const event: MessageEvent = { eventId: input.id, name: eventName, timestamp: new Date(input.createdAt).toISOString(),
          data: { inbox: "wearable", message_id: input.id, thread_id: input.id, text: input.text }, cursor: null };
        state.storage.sql.exec("INSERT INTO outbox VALUES (?, ?, ?, ?, 0, 'pending', NULL)", input.id, subscription.body.result.id, JSON.stringify(event), Date.now() - 1);
      }
    });
    receiverHook = async event => {
      if (event.data.message_id === first.id) await owner().execute({ kind: "reply", input: { message_id: second.id, text: "已从 inbox 回复第二条" } });
    };
    await dispatch();
    expect(await (await request(`/v2/receipts/${second.id}`)).json()).toMatchObject({ state: "replied" });
    expect(events.filter(e => e.data.message_id === second.id)).toHaveLength(0);
  });
  it("does not exceed the retry budget after a crash on the fifth delivery attempt", async () => {
    await connect(); status = 503; const input = command(); await send(input);
    await runInDurableObject(owner(), async (_instance, state) => {
      state.storage.sql.exec("UPDATE outbox SET state = 'dispatching', attempts = 5, lease = 'crashed', due_at = ? WHERE id = ?", Date.now() - 1, input.id);
    });
    const before = events.length; await abortAllDurableObjects(); await dispatch();
    expect(events).toHaveLength(before);
    expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ state: "delivery_failed" });
  });
  it("does not revive a subscription revoked during callback verification", async () => {
    network.use(http.post(callback, async ({ request }) => {
      const payload = await request.json() as { challenge: string };
      await owner().execute({ kind: "unsubscribe", input: { name: eventName, arguments: { inbox: "wearable" }, delivery: { mode: "webhook", url: callback } } });
      return Response.json({ challenge: payload.challenge });
    }));
    expect((await connect()).body.error).toMatchObject({ message: "subscription_changed" });
    expect(await (await request("/v2/status")).json()).toMatchObject({ subscribed: false });
  });
  it("does not apply an in-flight acknowledgement after unsubscribe", async () => {
    await connect(); const input = command(); await send(input);
    receiverHook = async () => { await owner().execute({ kind: "unsubscribe", input: { name: eventName, arguments: { inbox: "wearable" }, delivery: { mode: "webhook", url: callback } } }); };
    await dispatch(); expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ state: "delivery_failed" });
    expect(await (await request("/v2/status")).json()).toMatchObject({ subscribed: false });
  });
  it("keeps stable subscription identity while rotating webhook signatures", async () => {
    const initial = await connect(); const rotated = `whsec_${btoa("n".repeat(32))}`;
    const signatures: string[] = [];
    network.use(http.post(callback, async ({ request }) => {
      const body = await request.text();
      const headers = { "webhook-id": request.headers.get("webhook-id")!, "webhook-timestamp": request.headers.get("webhook-timestamp")!, "webhook-signature": request.headers.get("webhook-signature")! };
      const payload = new Webhook(rotated).verify(body, headers) as Record<string, unknown>;
      if (payload.type === "verification") return Response.json({ challenge: payload.challenge });
      new Webhook(secret).verify(body, headers); signatures.push(headers["webhook-signature"]);
      return new Response(null, { status: 202 });
    }));
    const changed = await rpc("events/subscribe", subscription(callback, rotated)); expect(changed.body.result.id).toBe(initial.body.result.id);
    await send(command()); await dispatch(); expect(signatures).toHaveLength(1); expect(signatures[0].split(" ")).toHaveLength(2);
  });
  it("stops delivery when unsubscribed and requires a fresh subscription", async () => {
    await connect(); const input = command(); await send(input);
    const stop = { name: eventName, arguments: { inbox: "wearable" }, delivery: { mode: "webhook", url: callback } };
    expect((await rpc("events/unsubscribe", stop)).body.error).toBeUndefined();
    expect((await rpc("events/unsubscribe", stop)).body.error).toBeUndefined();
    // A webhook that had already reached the receiver cannot be unsent.
    const atStop = events.length; await dispatch(); expect(events).toHaveLength(atStop);
    expect((await send(command())).status).toBe(503);
  });
  it("expires acknowledged messages on unsubscribe but preserves completed replies", async () => {
    await connect(); const waiting = command(), completed = command();
    await send(waiting); await send(completed); await dispatch();
    expect(await (await request(`/v2/receipts/${waiting.id}`)).json()).toMatchObject({ state: "delivered" });
    await reply(completed.id, "已完成🙂");
    const stop = { name: eventName, arguments: { inbox: "wearable" }, delivery: { mode: "webhook", url: callback } };
    await rpc("events/unsubscribe", stop);
    expect(await (await request(`/v2/receipts/${waiting.id}`)).json()).toMatchObject({ state: "expired" });
    expect(await (await request(`/v2/receipts/${completed.id}`)).json()).toMatchObject({ state: "replied", reply: "已完成🙂" });
    expect((await reply(waiting.id, "不应接受")).body.result.isError).toBe(true);
    expect(await (await request(`/v2/receipts/${waiting.id}`)).json()).toMatchObject({ state: "expired" });
  });
  it("expires subscriptions rather than displaying a false online status", async () => {
    await connect(); const input = command(); await send(input);
    await runInDurableObject(owner(), async (_instance, state) => {
      const rows = state.storage.sql.exec<{ id: string; value: string }>("SELECT * FROM subscriptions").toArray();
      for (const row of rows) { const sub = JSON.parse(row.value); sub.expiresAt = Date.now() - 1;
        state.storage.sql.exec("UPDATE subscriptions SET value = ? WHERE id = ?", JSON.stringify(sub), row.id); }
    });
    const atExpiry = events.length; await dispatch(); expect(events).toHaveLength(atExpiry);
    expect(await (await request("/v2/status")).json()).toMatchObject({ subscribed: false });
    expect(await (await request(`/v2/receipts/${input.id}`)).json()).toMatchObject({ state: "expired" });
  });
  it("simulates three turns and keeps exact message/reply history in one thread", async () => {
    await connect(); let thread: string | undefined;
    const text = ["请记住：松果-742🙂", "刚才的暗号是什么？", "只回复：中文跟进收发一致，测试结束🙂"];
    const mocked = ["已记住：松果-742🙂", "松果-742🙂", "中文跟进收发一致，测试结束🙂"];
    for (let i = 0; i < 3; i++) {
      const input = command(text[i], thread); const receipt = await (await send(input)).json() as { thread: string }; thread = receipt.thread;
      await dispatch(); await reply(input.id, mocked[i]);
    }
    const history = await (await request(`/v2/threads/${thread}`)).json() as { messages: { text: string; reply: string }[] };
    expect(history.messages.map(m => m.text)).toEqual(text); expect(history.messages.map(m => m.reply)).toEqual(mocked);
    expect(events.map(e => e.data.text)).toEqual(text); expect(new Set(events.map(e => e.data.thread_id)).size).toBe(1);
  });
  it("rejects malformed commands, foreign threads, stale timestamps and oversized data", async () => {
    await connect();
    expect((await send({ ...command(), createdAt: Date.now() - 2 * 86400_000 })).status).toBe(400);
    expect((await send(command("x", crypto.randomUUID()))).status).toBe(404);
    expect((await send(command("🙂".repeat(4001)))).status).toBe(400);
    expect((await request("/v2/messages", { ...command(), approve: true })).status).toBe(400);
    expect((await request("/v2/messages", { ...command(), text: "x".repeat(70000) })).status).toBe(413);
  });
});
