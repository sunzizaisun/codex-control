import { z } from "zod";
import { digest } from "../slack";
import { EventError, parse } from "./protocol";

// A finite, owner-admin-only storage/connection observation. Never dispatches
// an event, reads a different chat, refreshes authorization, or answers dot.
export const observationDuration = 86_400_000;
export const observationInterval = 1_800_000;
const schema = z.object({ id: z.uuid(), createdAt: z.number().int().safe(),
  messages: z.array(z.uuid()).min(1).max(4), syncs: z.array(z.uuid()).min(1).max(4) }).strict();
type Plan = z.infer<typeof schema>;
type Sample = { at: number; ok: boolean; reason?: string };
type Row = { id: string; plan: string; baseline: string; state: string; started_at: number;
  due_at: number; deadline: number; samples: string; reason: string | null };

export class DotStabilityObservation {
  constructor(private storage: DurableObjectStorage, private now: () => number = Date.now) {}
  initialize() {
    this.storage.sql.exec(`CREATE TABLE IF NOT EXISTS cloud_stability_runs (id TEXT PRIMARY KEY,
      plan TEXT NOT NULL, baseline TEXT NOT NULL, state TEXT NOT NULL, started_at INTEGER NOT NULL,
      due_at INTEGER NOT NULL, deadline INTEGER NOT NULL, samples TEXT NOT NULL, reason TEXT)`);
    this.storage.sql.exec("CREATE UNIQUE INDEX IF NOT EXISTS one_cloud_stability_run ON cloud_stability_runs(state) WHERE state = 'running'");
  }
  private row(id: string) { return this.storage.sql.exec<Row>("SELECT * FROM cloud_stability_runs WHERE id = ?", id.toLowerCase()).toArray()[0]; }
  private active() { return this.storage.sql.exec<Row>("SELECT * FROM cloud_stability_runs WHERE state = 'running' LIMIT 1").toArray()[0]; }
  nextDue() { return this.active()?.due_at; }
  status(id: string) {
    if (!z.uuid().safeParse(id).success) throw new EventError("invalid_params");
    const row = this.row(id); if (!row) throw new EventError("observation_not_found", -32000, 404);
    return this.view(row);
  }
  private view(row: Row) {
    const samples = JSON.parse(row.samples) as Sample[];
    return { id: row.id, state: row.state, startedAt: row.started_at, deadline: row.deadline,
      nextSampleAt: row.state === "running" ? row.due_at : null, intervalMs: observationInterval,
      elapsedMs: Math.max(0, (samples.at(-1)?.at ?? row.started_at) - row.started_at),
      samples, reason: row.reason, macBridgeUsed: false, messagesSent: 0,
      realDotConversationsTestedByObservation: false };
  }
  private async snapshot(plan: Plan) {
    const rows: { kind: string; id: string; hash: string }[] = [];
    for (const id of plan.messages) {
      const row = this.storage.sql.exec<{ thread_id: string; text: string; created_at: number; reply: string | null; replied_at: number | null; state: string }>(
        "SELECT thread_id, text, created_at, reply, replied_at, state FROM messages WHERE id = ?", id).toArray()[0];
      if (!row || row.state !== "replied" || row.reply === null || row.replied_at === null) throw new EventError("observation_record_unavailable", -32000, 409);
      rows.push({ kind: "message", id, hash: await digest(JSON.stringify(row)) });
    }
    for (const id of plan.syncs) {
      const row = this.storage.sql.exec<{ state: string; batch: string | null; completed_at: number | null; imported: number; duplicates: number; mirrored: number; truncated: number }>(
        "SELECT state, batch, completed_at, imported, duplicates, mirrored, truncated FROM history_sync_requests WHERE id = ? COLLATE NOCASE", id).toArray()[0];
      if (!row || row.state !== "completed" || row.batch === null || row.completed_at === null) throw new EventError("observation_record_unavailable", -32000, 409);
      rows.push({ kind: "sync", id, hash: await digest(JSON.stringify(row)) });
    }
    return JSON.stringify(rows);
  }
  async start(raw: unknown, subscribed: boolean) {
    const parsed = parse(schema, raw), plan = { ...parsed, id: parsed.id.toLowerCase(),
      messages: parsed.messages.map(id => id.toLowerCase()).sort(), syncs: parsed.syncs.map(id => id.toLowerCase()).sort() };
    if (new Set([...plan.messages, ...plan.syncs]).size !== plan.messages.length + plan.syncs.length) throw new EventError("invalid_params");
    const encoded = JSON.stringify(plan), old = this.row(plan.id);
    if (old) {
      if (old.plan !== encoded) throw new EventError("request_id_conflict", -32000, 409);
      return this.view(old);
    }
    if (!subscribed) throw new EventError("dot_not_subscribed", -32000, 503);
    if (Math.abs(this.now() - plan.createdAt) > 60_000) throw new EventError("stale_command");
    const baseline = await this.snapshot(plan);
    // Hashing yields: recheck the idempotent ID and running slot afterwards.
    this.storage.transactionSync(() => {
      const existing = this.row(plan.id);
      if (existing) {
        if (existing.plan !== encoded) throw new EventError("request_id_conflict", -32000, 409);
        return;
      }
      if (this.active()) throw new EventError("observation_already_running", -32000, 409);
      if (this.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM cloud_stability_runs").one().count >= 16) throw new EventError("observation_history_full", -32000, 507);
      const at = this.now();
      this.storage.sql.exec("INSERT INTO cloud_stability_runs VALUES (?, ?, ?, 'running', ?, ?, ?, ?, NULL)",
        plan.id, encoded, baseline, at, at + observationInterval, at + observationDuration, JSON.stringify([{ at, ok: true }]));
    });
    return this.status(plan.id);
  }
  async tick(subscribed: boolean) {
    const row = this.active(), at = this.now();
    if (!row || at < row.due_at) return;
    let reason: string | undefined;
    if (at - row.due_at > 600_000) reason = "observation_gap";
    else if (!subscribed) reason = "subscription_unavailable";
    else {
      try {
        if (await this.snapshot(parse(schema, JSON.parse(row.plan))) !== row.baseline) reason = "known_record_changed";
      } catch { reason = "observation_record_unavailable"; }
    }
    const samples = JSON.parse(row.samples) as Sample[];
    samples.push({ at, ok: reason === undefined, ...(reason ? { reason } : {}) });
    const state = reason ? "failed" : at >= row.deadline ? "completed" : "running";
    // An overlapping alarm cannot append the same sample twice. Public GETs
    // never call tick, so checking the report cannot accelerate the test.
    this.storage.sql.exec("UPDATE cloud_stability_runs SET state = ?, samples = ?, due_at = ?, reason = ? WHERE id = ? AND state = 'running' AND due_at = ?",
      state, JSON.stringify(samples), Math.min(row.deadline, row.due_at + observationInterval), reason ?? null, row.id, row.due_at);
  }
}
