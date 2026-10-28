import { DurableObject } from "cloudflare:workers";
import { authorized, boundedJSON, digest, GatewayError, object, readableSlackText, slackAPI, slackText, validTimestamp, type JSONObject } from "./slack";

type Receipt = { id: string; state: "sending" | "sent" | "uncertain" | "rejected"; thread?: string; timestamp?: string; error?: string };
type SendInput = { id: string; text: string; createdAt: number; thread?: string };
type Message = { id: string; role: "user" | "assistant"; text: string; sentAt: number; controlsInSlack: boolean };
type Page = { messages: Message[]; nextCursor?: string; capturedAt: number };
type Operation = { kind: "connection" } | { kind: "threads"; cursor: string } | { kind: "thread"; ts: string; cursor: string; after?: string } | { kind: "receipt"; id: string } | { kind: "send"; input: SendInput };

export class DotAccount extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS receipts (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, receipt TEXT NOT NULL, created_at INTEGER NOT NULL)`);
      ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS cache (key TEXT PRIMARY KEY, value TEXT NOT NULL, expires_at INTEGER NOT NULL)`);
      ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS quota (method TEXT PRIMARY KEY, started_at INTEGER NOT NULL, count INTEGER NOT NULL, last_at INTEGER NOT NULL)`);
      ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS roots (ts TEXT PRIMARY KEY)`);
    });
  }

  async execute(operation: Operation): Promise<{ ok: true; value: unknown } | { ok: false; error: string; status: number; retryAfter?: number }> {
    // Preserve error codes and Retry-After across RPC serialization, which
    // does not preserve a custom Error subclass's extra properties.
    try {
      let value: unknown;
      switch (operation.kind) {
        case "connection": value = await this.connection(); break;
        case "threads": value = await this.threads(operation.cursor); break;
        case "thread": value = await this.thread(operation.ts, operation.cursor, operation.after); break;
        case "receipt": value = await this.receipt(operation.id); break;
        case "send": value = await this.send(operation.input); break;
      }
      return { ok: true, value };
    } catch (error) {
      const known = error instanceof GatewayError ? error : new GatewayError("gateway_unavailable", 503);
      return { ok: false, error: known.code, status: known.status, ...(known.retryAfter ? { retryAfter: known.retryAfter } : {}) };
    }
  }

  private cached<T>(key: string): T | undefined {
    const row = this.ctx.storage.sql.exec<{ value: string; expires_at: number }>("SELECT value, expires_at FROM cache WHERE key = ?", key).toArray()[0];
    return row && row.expires_at > Date.now() ? JSON.parse(row.value) : undefined;
  }
  private cache(key: string, value: unknown, ttl: number) {
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO cache VALUES (?, ?, ?)", key, JSON.stringify(value), Date.now() + ttl);
  }
  private quota(method: string) {
    const now = Date.now();
    const row = this.ctx.storage.sql.exec<{ started_at: number; count: number; last_at: number }>("SELECT * FROM quota WHERE method = ?", method).toArray()[0];
    if (row && method === "chat.postMessage" && now - row.last_at < 1100) throw new GatewayError("rate_limited", 429, 2);
    if (row && now - row.started_at < 60_000 && row.count >= 40) {
      throw new GatewayError("rate_limited", 429, Math.ceil((row.started_at + 60_000 - now) / 1000));
    }
    const fresh = !row || now - row.started_at >= 60_000;
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO quota VALUES (?, ?, ?, ?)", method, fresh ? now : row.started_at, fresh ? 1 : row.count + 1, now);
  }
  private async api(method: string, data: JSONObject = {}, write = false) {
    this.quota(method);
    return slackAPI(this.env.SLACK_USER_TOKEN, method, data, write);
  }
  async connection() {
    const existing = this.cached<{ connected: boolean; dotName: string; verifiedAt: number }>("connection");
    if (existing) return existing;
    const auth = await this.api("auth.test");
    if (auth.team_id !== this.env.SLACK_TEAM_ID || auth.user_id !== this.env.SLACK_OWNER_ID) throw new GatewayError("account_mismatch", 403);
    const info = await this.api("conversations.info", { channel: this.env.SLACK_DOT_CHANNEL });
    const channel = object(info.channel);
    if (channel.id !== this.env.SLACK_DOT_CHANNEL || channel.is_im !== true || channel.user !== this.env.SLACK_DOT_ID) throw new GatewayError("dot_mismatch", 403);
    const value = { connected: true, dotName: this.env.DOT_NAME, verifiedAt: Date.now(), capabilities: { messaging: true, runtimeStatus: false, approvals: false } };
    this.cache("connection", value, 30_000);
    return value;
  }
  private message(value: unknown): Message | undefined {
    const item = object(value);
    if (!validTimestamp(item.ts) || (item.user !== this.env.SLACK_OWNER_ID && item.user !== this.env.SLACK_DOT_ID)) return undefined;
    if (typeof item.text !== "string") return undefined;
    // Only text is projected. Foreign Block Kit action callbacks must never be
    // impersonated as formal approvals from our own app.
    const blocks = Array.isArray(item.blocks) ? item.blocks : [];
    const controlsInSlack = blocks.some(b => object(b).type === "actions");
    const text = readableSlackText(item.text.replace(new RegExp(`^<@${this.env.SLACK_DOT_ID}(?:\\|[^>]+)?>\\s*`), ""), blocks);
    return { id: item.ts, role: item.user === this.env.SLACK_OWNER_ID ? "user" : "assistant", text, sentAt: Math.floor(Number(item.ts) * 1000), controlsInSlack };
  }
  async threads(cursor = "") {
    await this.connection();
    const key = `threads:${cursor}`;
    const cached = this.cached<{ threads: { id: string; title: string; updatedAt: number }[]; nextCursor?: string }>(key);
    if (cached) return cached;
    const response = await this.api("conversations.history", { channel: this.env.SLACK_DOT_CHANNEL, limit: 15, ...(cursor ? { cursor } : {}) });
    if (!Array.isArray(response.messages)) throw new GatewayError("invalid_response");
    const threads = response.messages.flatMap(value => {
      const raw = object(value);
      const message = this.message(raw);
      if (!message || (raw.thread_ts && raw.thread_ts !== raw.ts)) return [];
      this.ctx.storage.sql.exec("INSERT OR IGNORE INTO roots VALUES (?)", message.id);
      return [{ id: message.id, title: message.text.slice(0, 100), updatedAt: message.sentAt }];
    });
    const next = this.cursor(response);
    const result = { threads, ...(next ? { nextCursor: next } : {}) };
    this.cache(key, result, 8000);
    return result;
  }
  private cursor(response: JSONObject): string | undefined {
    const meta = response.response_metadata ? object(response.response_metadata) : {};
    const value = meta.next_cursor;
    return typeof value === "string" && value.length > 0 ? value : undefined;
  }
  private knownRoot(ts: string) { return this.ctx.storage.sql.exec("SELECT ts FROM roots WHERE ts = ?", ts).toArray().length > 0; }
  async thread(ts: string, cursor = "", after?: string): Promise<Page> {
    if (!validTimestamp(ts)) throw new GatewayError("invalid_thread", 400);
    if (after !== undefined && (!validTimestamp(after) || after < ts)) throw new GatewayError("invalid_after", 400);
    if ((cursor || after) && !this.knownRoot(ts)) throw new GatewayError("invalid_thread", 400);
    await this.connection();
    const key = `thread:${ts}:${cursor}:${after || ""}`;
    const cached = this.cached<Page>(key);
    if (cached) return cached;
    const response = await this.api("conversations.replies", { channel: this.env.SLACK_DOT_CHANNEL, ts, limit: 15, ...(cursor ? { cursor } : {}), ...(after ? { oldest: after, inclusive: true } : {}) });
    if (!Array.isArray(response.messages)) throw new GatewayError("invalid_response");
    if (!cursor && !after) {
      const parent = response.messages[0] && this.message(response.messages[0]);
      if (!parent || parent.id !== ts) throw new GatewayError("invalid_thread", 400);
      this.ctx.storage.sql.exec("INSERT OR IGNORE INTO roots VALUES (?)", ts);
    }
    const messages = response.messages.flatMap(value => { const m = this.message(value); return m ? [m] : []; });
    const next = this.cursor(response);
    const page = { messages, ...(next ? { nextCursor: next } : {}), capturedAt: Date.now() };
    this.cache(key, page, 2000);
    return page;
  }
  async receipt(id: string): Promise<Receipt | null> {
    const row = this.ctx.storage.sql.exec<{ receipt: string }>("SELECT receipt FROM receipts WHERE id = ?", id).toArray()[0];
    return row ? JSON.parse(row.receipt) : null;
  }
  async send(input: SendInput): Promise<Receipt> {
    const fingerprint = await digest(JSON.stringify([input.text, input.thread || "", input.createdAt]));
    const stored = this.ctx.storage.sql.exec<{ fingerprint: string; receipt: string }>("SELECT * FROM receipts WHERE id = ?", input.id).toArray()[0];
    if (stored) {
      if (stored.fingerprint !== fingerprint) throw new GatewayError("request_id_conflict", 409);
      return JSON.parse(stored.receipt);
    }
    if (input.createdAt > Date.now() + 60_000 || input.createdAt < Date.now() - 24 * 60 * 60_000) throw new GatewayError("stale_command", 400);
    await this.connection();
    if (input.thread && !this.knownRoot(input.thread)) await this.thread(input.thread);
    // Recheck after external I/O: concurrent requests may have completed the
    // same ID while identity/thread validation was in flight.
    const again = this.ctx.storage.sql.exec<{ fingerprint: string; receipt: string }>("SELECT * FROM receipts WHERE id = ?", input.id).toArray()[0];
    if (again) {
      if (again.fingerprint !== fingerprint) throw new GatewayError("request_id_conflict", 409);
      return JSON.parse(again.receipt);
    }
    this.quota("chat.postMessage");
    const pending: Receipt = { id: input.id, state: "sending", ...(input.thread ? { thread: input.thread } : {}) };
    this.ctx.storage.sql.exec("INSERT INTO receipts VALUES (?, ?, ?, ?)", input.id, fingerprint, JSON.stringify(pending), Date.now());
    let result: Receipt;
    try {
      const response = await slackAPI(this.env.SLACK_USER_TOKEN, "chat.postMessage", {
        channel: this.env.SLACK_DOT_CHANNEL,
        // Actual dot testing showed thread follow-ups without an explicit
        // mention could be ignored. Keep the real message unchanged after it.
        text: `<@${this.env.SLACK_DOT_ID}> ${slackText(input.text)}`,
        // Slack needs markup parsing for the explicit user mention to notify
        // dot. User-supplied angle brackets remain escaped above, so they
        // cannot create mentions of other users or broadcast groups.
        mrkdwn: true, parse: "none", unfurl_links: false, unfurl_media: false,
        ...(input.thread ? { thread_ts: input.thread } : {}),
      }, true);
      if (response.channel !== this.env.SLACK_DOT_CHANNEL || !validTimestamp(response.ts)) throw new GatewayError("delivery_uncertain");
      result = { id: input.id, state: "sent", timestamp: response.ts, thread: input.thread || response.ts };
      this.ctx.storage.sql.exec("INSERT OR IGNORE INTO roots VALUES (?)", result.thread!);
      this.ctx.storage.sql.exec("DELETE FROM cache WHERE key LIKE 'threads:%' OR key LIKE ?", `thread:${result.thread}:%`);
    } catch (error) {
      const known = error instanceof GatewayError ? error : new GatewayError("delivery_uncertain");
      // A confirmed HTTP 429 never accepted the message. Allow a later caller
      // with the SAME ID to try again, but do not retry on uncertain errors.
      if (known.status === 429) {
        this.ctx.storage.sql.exec("DELETE FROM receipts WHERE id = ?", input.id);
        throw known;
      }
      result = { ...pending, state: known.code === "delivery_uncertain" ? "uncertain" : "rejected", error: known.code };
      this.ctx.storage.sql.exec("DELETE FROM cache WHERE key = 'connection'");
    }
    this.ctx.storage.sql.exec("UPDATE receipts SET receipt = ? WHERE id = ?", JSON.stringify(result), input.id);
    // No polling while nobody is using the companion; no sleeping Mac or
    // always-awake browser is involved in this channel.
    this.ctx.storage.sql.exec("DELETE FROM receipts WHERE created_at < ?", Date.now() - 7 * 24 * 60 * 60_000);
    this.ctx.storage.sql.exec("DELETE FROM cache WHERE expires_at < ?", Date.now() - 60_000);
    return result;
  }
}

function json(value: unknown, status = 200, retryAfter?: number) {
  return Response.json(value, { status, headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...(retryAfter ? { "Retry-After": String(retryAfter) } : {}) } });
}
function operationResponse(result: { ok: true; value: unknown } | { ok: false; error: string; status: number; retryAfter?: number }): Response {
  return result.ok ? (result.value === null ? json({ error: "receipt_not_found" }, 404) : json(result.value)) : json({ error: result.error, ...(result.retryAfter ? { retryAfter: result.retryAfter } : {}) }, result.status, result.retryAfter);
}
function validateSend(value: unknown): SendInput {
  const body = object(value);
  if (Object.keys(body).some(key => !["id", "text", "createdAt", "thread"].includes(key))) throw new GatewayError("unexpected_field", 400);
  if (typeof body.id !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.id)) throw new GatewayError("invalid_id", 400);
  if (typeof body.text !== "string" || !body.text.trim() || [...body.text].length > 4000) throw new GatewayError("invalid_text", 400);
  if (typeof body.createdAt !== "number" || !Number.isSafeInteger(body.createdAt)) throw new GatewayError("invalid_date", 400);
  if (body.thread !== undefined && !validTimestamp(body.thread)) throw new GatewayError("invalid_thread", 400);
  return { id: body.id, text: body.text, createdAt: body.createdAt, ...(typeof body.thread === "string" ? { thread: body.thread } : {}) };
}
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health" && request.method === "GET") return json({ ok: true, protocol: 1 });
    if (!url.pathname.startsWith("/v1/")) return json({ error: "not_found" }, 404);
    if (!await authorized(request, env.DOTS_AUTH_KEY)) return json({ error: "unauthorized" }, 401);
    if (!env.SLACK_USER_TOKEN) return json({ error: "not_configured" }, 503);
    try {
      const account = env.DOT_ACCOUNTS.getByName(`${env.SLACK_TEAM_ID}:${env.SLACK_OWNER_ID}`);
      const cursor = url.searchParams.get("cursor") || "";
      if (cursor.length > 512) throw new GatewayError("invalid_cursor", 400);
      if (url.pathname === "/v1/connection" && request.method === "GET") return operationResponse(await account.execute({ kind: "connection" }));
      if (url.pathname === "/v1/threads" && request.method === "GET") return operationResponse(await account.execute({ kind: "threads", cursor }));
      const thread = url.pathname.match(/^\/v1\/threads\/([0-9.]+)$/);
      if (thread && request.method === "GET") return operationResponse(await account.execute({ kind: "thread", ts: thread[1], cursor, ...(url.searchParams.has("after") ? { after: url.searchParams.get("after")! } : {}) }));
      if (url.pathname === "/v1/messages" && request.method === "POST") return operationResponse(await account.execute({ kind: "send", input: validateSend(await boundedJSON(request.body, 64 * 1024)) }));
      const receipt = url.pathname.match(/^\/v1\/receipts\/([a-fA-F0-9-]{36})$/);
      if (receipt && request.method === "GET") {
        return operationResponse(await account.execute({ kind: "receipt", id: receipt[1] }));
      }
      return json({ error: "not_found" }, 404);
    } catch (error) {
      // RPC errors retain only the message reliably; all messages generated
      // by this service are non-sensitive machine-readable error codes.
      const known = error instanceof GatewayError ? error : new GatewayError("gateway_unavailable", 503);
      return json({ error: known.code, ...(known.retryAfter ? { retryAfter: known.retryAfter } : {}) }, known.status, known.retryAfter);
    }
  },
} satisfies ExportedHandler<Env>;
