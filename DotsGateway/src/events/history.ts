import { z } from "zod";
import { boundedText, EventError, parse } from "./protocol";
import { companionMirrorID, verifiedCompanionMirror } from "./mirror";
import { markRequestRead, type MCPRequestTiming } from "./request-timing";

// This owner explicitly authorized ONLY this Your dot room. Not client-supplied
// configuration: neither a paired device nor the model can choose another room.
export const authorizedDotRoom = "00000000000000000000000000000000";
export const syncRequestSchema = z.object({ id: z.uuid(), createdAt: z.number().int().safe() }).strict();
const originalID = z.string().regex(/^[A-Za-z0-9_-]{1,128}$/);
export const historyImportSchema = z.object({
  request_id: z.uuid(), room_id: z.literal(authorizedDotRoom),
  messages: z.array(z.object({ id: originalID, role: z.enum(["user", "assistant"]),
    text: boundedText(16000), sentAt: z.number().int().safe().positive() }).strict()).max(30),
  truncated: z.boolean(),
}).strict();
type RequestRow = { id: string; created_at: number; expires_at: number; recover_until: number | null; state: string; sub_id: string; batch: string | null; imported: number; duplicates: number; mirrored: number; truncated: number; completed_at: number | null;
  import_started_at: number | null; import_attempts: number; import_failed_at: number | null; import_error: string | null };
type OfficialRow = { id: string; role: string; text: string; sent_at: number; visible: number };
// Seek each indexed source independently. The original compound SELECT with
// its timing join does not reliably push LIMIT through the global sort.
export const sharedHistoryQueries = [
  `SELECT m.id || '.user' AS id, 'user' AS role, m.text, m.created_at AS sentAt,
    m.state AS deliveryState, t.read_at AS readAt FROM messages m
    LEFT JOIN message_timings t ON t.id = m.id
    WHERE (m.created_at, m.id || '.user') < (?, ?)
    ORDER BY m.created_at DESC, m.id || '.user' DESC LIMIT 31`,
  `SELECT id || '.reply' AS id, 'assistant' AS role, reply AS text, replied_at AS sentAt,
    NULL AS deliveryState, NULL AS readAt FROM messages WHERE reply IS NOT NULL
    AND (replied_at, id || '.reply') < (?, ?)
    ORDER BY replied_at DESC, id || '.reply' DESC LIMIT 31`,
  `SELECT 'official.' || id AS id, role, text, sent_at AS sentAt,
    NULL AS deliveryState, NULL AS readAt FROM official_dot_messages WHERE visible = 1
    AND (sent_at, 'official.' || id) < (?, ?)
    ORDER BY sent_at DESC, 'official.' || id DESC LIMIT 31`,
] as const;
export class DotHistory {
  constructor(private storage: DurableObjectStorage, private now: () => number = Date.now) {}
  initialize() {
    this.storage.sql.exec(`CREATE TABLE IF NOT EXISTS history_sync_requests (id TEXT PRIMARY KEY,
      created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, state TEXT NOT NULL, sub_id TEXT NOT NULL,
      batch TEXT, imported INTEGER NOT NULL DEFAULT 0, duplicates INTEGER NOT NULL DEFAULT 0,
      mirrored INTEGER NOT NULL DEFAULT 0, truncated INTEGER NOT NULL DEFAULT 0,
      completed_at INTEGER)`);
    // Additive migration preserves existing requests and their replay receipts.
    if (!this.storage.sql.exec<{ name: string }>("PRAGMA table_info(history_sync_requests)").toArray().some(column => column.name === "completed_at")) {
      this.storage.sql.exec("ALTER TABLE history_sync_requests ADD COLUMN completed_at INTEGER");
    }
    if (!this.storage.sql.exec<{ name: string }>("PRAGMA table_info(history_sync_requests)").toArray().some(column => column.name === "recover_until")) {
      // Old expired rows may have been revoked; never resurrect them.
      this.storage.sql.exec("ALTER TABLE history_sync_requests ADD COLUMN recover_until INTEGER");
    }
    // Add only operational metadata. Never backfill an old request with a
    // guessed observation time, and never store failed payload text here.
    const columns = this.storage.sql.exec<{ name: string }>("PRAGMA table_info(history_sync_requests)").toArray().map(column => column.name);
    for (const [name, definition] of [["import_started_at", "INTEGER"], ["import_attempts", "INTEGER NOT NULL DEFAULT 0"],
      ["import_failed_at", "INTEGER"], ["import_error", "TEXT"]]) {
      if (!columns.includes(name)) this.storage.sql.exec(`ALTER TABLE history_sync_requests ADD COLUMN ${name} ${definition}`);
    }
    this.storage.sql.exec(`CREATE TABLE IF NOT EXISTS official_dot_messages (id TEXT PRIMARY KEY,
      role TEXT NOT NULL, text TEXT NOT NULL, sent_at INTEGER NOT NULL, visible INTEGER NOT NULL)`);
    this.storage.sql.exec("CREATE INDEX IF NOT EXISTS shared_user_page ON messages(created_at, id || '.user')");
    this.storage.sql.exec("CREATE INDEX IF NOT EXISTS shared_reply_page ON messages(replied_at, id || '.reply') WHERE reply IS NOT NULL");
    this.storage.sql.exec("CREATE INDEX IF NOT EXISTS shared_official_page ON official_dot_messages(sent_at, 'official.' || id) WHERE visible = 1");
    this.storage.sql.exec("CREATE INDEX IF NOT EXISTS history_sync_expiry ON history_sync_requests(state, expires_at, recover_until)");
    // Older clients could submit mixed-case UUIDs. Keep those receipts and
    // their outbox IDs intact while treating future lookups as one identity.
    this.storage.sql.exec("CREATE INDEX IF NOT EXISTS history_sync_uuid ON history_sync_requests(id COLLATE NOCASE)");
  }
  expire() {
    // A 2xx only acknowledges delivery. Keep a bounded, already-delivered
    // control request recoverable when the upstream task starts late. No new
    // event, background polling or repeated import is created here.
    this.storage.sql.exec(`UPDATE history_sync_requests SET state = 'delayed'
      WHERE state = 'pending' AND expires_at <= ? AND recover_until > ?
      AND id IN (SELECT id FROM outbox WHERE state = 'acknowledged')`, this.now(), this.now());
    this.storage.sql.exec("UPDATE history_sync_requests SET state = 'expired' WHERE state = 'pending' AND expires_at <= ?", this.now());
    this.storage.sql.exec("UPDATE history_sync_requests SET state = 'expired' WHERE state = 'delayed' AND recover_until <= ?", this.now());
    // Start from the small live outbox, not every expired sync ever retained.
    this.storage.sql.exec("UPDATE outbox SET state = 'expired', lease = NULL WHERE state IN ('pending', 'dispatching') AND EXISTS (SELECT 1 FROM history_sync_requests h WHERE h.id = outbox.id AND h.state = 'expired')");
  }
  request(raw: unknown, subID: string) {
    const parsed = parse(syncRequestSchema, raw), input = { ...parsed, id: parsed.id.toLowerCase() }, now = this.now();
    this.expire();
    const existing = this.row(input.id);
    if (existing) {
      if (existing.created_at !== input.createdAt) throw new EventError("request_id_conflict", -32000, 409);
      return { created: false, receipt: this.view(existing) };
    }
    if (Math.abs(input.createdAt - now) > 60_000) throw new EventError("stale_command");
    // Coalesce simultaneous phone/Watch refreshes AND completed requests during
    // a short cooldown. UI polling never creates another model run.
    const recent = this.storage.sql.exec<RequestRow>("SELECT * FROM history_sync_requests WHERE sub_id = ? AND (state IN ('pending', 'delayed') OR created_at > ?) ORDER BY created_at DESC LIMIT 1", subID, now - 60_000).toArray()[0];
    if (recent) return { created: false, receipt: this.view(recent) };
    // Retain a bounded idempotency window; old IDs are stale on re-submission.
    this.storage.sql.exec("DELETE FROM history_sync_requests WHERE expires_at < ? AND state NOT IN ('pending', 'delayed')", now - 86400_000);
    this.storage.sql.exec("INSERT INTO history_sync_requests (id, created_at, expires_at, recover_until, state, sub_id) VALUES (?, ?, ?, ?, 'pending', ?)", input.id, input.createdAt, now + 300_000, now + 86400_000, subID);
    return { created: true, receipt: this.status(input.id) };
  }
  pending(requestTiming?: MCPRequestTiming) {
    this.expire();
    return this.storage.sql.exec<RequestRow>("SELECT * FROM history_sync_requests WHERE state IN ('pending', 'delayed') ORDER BY created_at LIMIT 1").toArray().map(row => {
      markRequestRead(this.storage, row.id, requestTiming, this.now());
      return this.view(row);
    });
  }
  status(id: string) {
    if (!z.uuid().safeParse(id).success) throw new EventError("invalid_params");
    this.expire();
    const row = this.row(id);
    if (!row) throw new EventError("sync_not_found", -32000, 404);
    return this.view(row);
  }
  private row(id: string) { return this.storage.sql.exec<RequestRow>("SELECT * FROM history_sync_requests WHERE id = ? COLLATE NOCASE", id).toArray()[0]; }
  private view(row: RequestRow) {
    const delivery = this.storage.sql.exec<{ state: string; attempts: number }>("SELECT state, attempts FROM outbox WHERE id = ?", row.id).toArray()[0];
    const timing = this.storage.sql.exec<{ accepted_at: number; dispatched_at: number | null; acknowledged_at: number | null;
      read_at: number | null; mcp_received_at: number | null; mcp_authorized_at: number | null }>("SELECT * FROM message_timings WHERE id = ?", row.id).toArray()[0];
    return { id: row.id, state: row.state, createdAt: row.created_at, expiresAt: row.expires_at, recoverableUntil: row.recover_until,
      imported: row.imported, duplicates: row.duplicates, mirrored: row.mirrored, truncated: !!row.truncated,
      deliveryState: delivery?.state ?? "pending", deliveryAttempts: delivery?.attempts ?? 0,
      completedAt: row.completed_at,
      ...(timing ? { timing: { acceptedAt: timing.accepted_at, dispatchedAt: timing.dispatched_at, acknowledgedAt: timing.acknowledged_at,
        readAt: timing.read_at, ...(timing.mcp_received_at !== null && timing.mcp_authorized_at !== null
          ? { mcpReceivedAt: timing.mcp_received_at, mcpAuthorizedAt: timing.mcp_authorized_at } : {}) } } : {}),
      historyImport: { startedAt: row.import_started_at, attempts: row.import_attempts,
        lastFailedAt: row.import_failed_at, lastError: row.import_error },
      room_id: authorizedDotRoom, ...this.completedBatch(row) };
  }
  private completedBatch(row: RequestRow) {
    if (row.state !== "completed" || row.batch === null) return {};
    // Reuse the already validated <=30-row import, not a fresh official read
    // or a scan of lifetime history. Native records can predate the latest
    // timeline page; returning this exact batch prevents a successful import
    // from remaining invisible to a device that expanded older pages earlier.
    let decoded: unknown;
    try { decoded = JSON.parse(row.batch); }
    catch { throw new EventError("history_sync_failed", -32603, 500); }
    const batch = z.tuple([z.boolean(), historyImportSchema.shape.messages]).safeParse(decoded);
    if (!batch.success) throw new EventError("history_sync_failed", -32603, 500);
    const messages: { id: string; role: string; text: string; sentAt: number; controlsInSlack: boolean }[] = [];
    const hiddenMessageIDs: string[] = [];
    for (const item of batch.data[1]) {
      const saved = this.storage.sql.exec<OfficialRow>("SELECT * FROM official_dot_messages WHERE id = ?", item.id).toArray()[0];
      if (!saved || saved.role !== item.role || saved.text !== item.text || saved.sent_at !== item.sentAt) throw new EventError("history_sync_failed", -32603, 500);
      if (!saved.visible) hiddenMessageIDs.push("official." + item.id);
      else messages.push({ id: "official." + item.id, role: item.role, text: item.text, sentAt: item.sentAt, controlsInSlack: false });
    }
    messages.sort((a, b) => a.sentAt - b.sentAt || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    return { messages, hiddenMessageIDs };
  }
  fail(id: string, state: string) {
    this.storage.sql.exec("UPDATE history_sync_requests SET state = ? WHERE id = ? AND state IN ('pending', 'delayed')", state, id);
  }
  revoke(subID: string) {
    this.storage.sql.exec("UPDATE history_sync_requests SET state = 'expired', recover_until = NULL WHERE sub_id = ? AND state IN ('pending', 'delayed')", subID);
  }
  import(raw: unknown, subID: string, requestTiming?: MCPRequestTiming) {
    const input = parse(historyImportSchema, raw);
    if (new TextEncoder().encode(JSON.stringify(input)).byteLength > 48 * 1024) throw new EventError("payload_too_large", -32602, 413);
    this.expire();
    const request = this.row(input.request_id);
    if (!request || request.sub_id !== subID) throw new EventError("sync_not_found", -32000, 404);
    const batch = JSON.stringify([input.truncated, [...input.messages].sort((a, b) => a.id.localeCompare(b.id))]);
    if (request.state === "completed") {
      if (request.batch !== batch) throw new EventError("sync_conflict", -32000, 409);
      return this.view(request);
    }
    if (!["pending", "delayed"].includes(request.state)) throw new EventError("sync_not_pending", -32000, 409);
    markRequestRead(this.storage, request.id, requestTiming, this.now());
    this.storage.sql.exec("UPDATE history_sync_requests SET import_started_at = COALESCE(import_started_at, ?), import_attempts = import_attempts + 1 WHERE id = ?", this.now(), request.id);
    try { return this.importBatch(input, request, batch); }
    catch (error) {
      // Diagnostic writes intentionally survive a rolled-back batch. Only a
      // known machine code is retained, never an exception or message body.
      this.storage.sql.exec("UPDATE history_sync_requests SET import_failed_at = ?, import_error = ? WHERE id = ?", this.now(),
        error instanceof EventError ? error.code : "history_sync_failed", request.id);
      throw error;
    }
  }
  private importBatch(input: z.infer<typeof historyImportSchema>, request: RequestRow, batch: string) {
    const ids = new Set<string>();
    let duplicates = 0, mirrored = 0;
    const repairs: string[] = [];
    const fresh: OfficialRow[] = [];
    for (const item of input.messages) {
      if (ids.has(item.id) || item.sentAt > this.now() + 60_000) throw new EventError("invalid_params");
      ids.add(item.id);
      const saved = this.storage.sql.exec<OfficialRow>("SELECT * FROM official_dot_messages WHERE id = ?", item.id).toArray()[0];
      if (saved) {
        if (saved.role !== item.role || saved.text !== item.text || saved.sent_at !== item.sentAt) throw new EventError("history_conflict", -32000, 409);
      }
      // Only hide a mirror when its entire original+reply text exactly matches
      // a stored companion exchange. A spoofed suffix cannot hide arbitrary text.
      const mirrorID = item.role === "assistant" ? companionMirrorID(item.text) : undefined;
      const source = mirrorID ? this.storage.sql.exec<{ text: string; reply: string | null }>("SELECT text, reply FROM messages WHERE id = ?", mirrorID).toArray()[0] : undefined;
      const isMirror = !!mirrorID && verifiedCompanionMirror(item.text, mirrorID, source);
      if (saved) {
        // Reconcile only the explicitly supplied, validated <=30-row batch.
        // Keep original IDs/text/times and frozen previous sync receipts.
        if (saved.visible && isMirror) repairs.push(saved.id);
        else duplicates++;
        continue;
      }
      if (isMirror) mirrored++;
      fresh.push({ id: item.id, role: item.role, text: item.text, sent_at: item.sentAt, visible: isMirror ? 0 : 1 });
    }
    const count = this.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM official_dot_messages").one().count;
    if (count + fresh.length > 10000) throw new EventError("history_full", -32000, 507);
    // All validation precedes writes; transactionSync also rolls back SQL errors.
    this.storage.transactionSync(() => {
      for (const row of fresh) this.storage.sql.exec("INSERT INTO official_dot_messages VALUES (?, ?, ?, ?, ?)", row.id, row.role, row.text, row.sent_at, row.visible);
      for (const id of repairs) this.storage.sql.exec("UPDATE official_dot_messages SET visible = 0 WHERE id = ? AND visible = 1", id);
      this.storage.sql.exec("UPDATE history_sync_requests SET state = 'completed', batch = ?, imported = ?, duplicates = ?, mirrored = ?, truncated = ?, completed_at = ? WHERE id = ?", batch, fresh.length - mirrored, duplicates, mirrored + repairs.length, input.truncated ? 1 : 0, this.now(), request.id);
      this.storage.sql.exec("UPDATE outbox SET state = 'answered', lease = NULL WHERE id = ?", request.id);
    });
    return this.status(request.id);
  }
  timeline(cursor?: string) {
    let time = Number.MAX_SAFE_INTEGER, id = "";
    if (cursor !== undefined) {
      const match = /^([1-9][0-9]{0,15})\.([A-Za-z0-9_.-]{1,180})$/.exec(cursor);
      if (!match || !Number.isSafeInteger(Number(match[1]))) throw new EventError("invalid_cursor");
      time = Number(match[1]); id = match[2];
    }
    type TimelineRow = { id: string; role: string; text: string; sentAt: number; deliveryState: string | null; readAt: number | null };
    const rows = sharedHistoryQueries.flatMap(query => this.storage.sql.exec<TimelineRow>(query, time, id).toArray())
      .sort((a, b) => b.sentAt - a.sentAt || (a.id < b.id ? 1 : a.id > b.id ? -1 : 0)).slice(0, 31);
    const page = rows.slice(0, 30), oldest = page.at(-1);
    return { messages: page.reverse().map(row => ({ ...row, controlsInSlack: false })),
      nextCursor: rows.length > 30 && oldest ? `${oldest.sentAt}.${oldest.id}` : null, capturedAt: this.now() };
  }
}
