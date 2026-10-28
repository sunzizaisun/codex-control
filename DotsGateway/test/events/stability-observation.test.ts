// Accelerated local fixtures only. These answers are not real dot replies.
import { env } from "cloudflare:workers";
import { abortAllDurableObjects, reset, runInDurableObject } from "cloudflare:test";
import { afterEach, expect, it } from "vitest";
import { DotStabilityObservation, observationDuration, observationInterval } from "../../src/events/stability-observation";

const owner = () => env.EVENT_INBOXES.getByName(env.EVENTS_OWNER);
afterEach(async () => { await reset(); });
async function fixture() {
  await owner().execute({ kind: "status" });
  const at = Date.now(), message = crypto.randomUUID(), sync = crypto.randomUUID();
  await runInDurableObject(owner(), async (_, state) => {
    state.storage.sql.exec("INSERT INTO messages (id, thread_id, text, created_at, fingerprint, state, reply, replied_at) VALUES (?, ?, 'private fixture input🦦', ?, 'fixture', 'replied', 'mock reply🍁', ?)", message, message, at, at);
    state.storage.sql.exec("INSERT INTO history_sync_requests (id, created_at, expires_at, recover_until, state, sub_id, batch, completed_at) VALUES (?, ?, ?, ?, 'completed', 'fixture', '[false,[]]', ?)", sync, at, at + 300_000, at + observationDuration, at);
  });
  return { id: crypto.randomUUID(), createdAt: at, messages: [message], syncs: [sync] };
}
it("completes exactly 49 scheduled samples across 24 virtual hours and storage restarts, without sending anything", async () => {
  const plan = await fixture();
  await runInDurableObject(owner(), async (_, state) => {
    const observer = new DotStabilityObservation(state.storage, () => plan.createdAt);
    expect(await observer.start(plan, true)).toMatchObject({ state: "running", samples: [{ at: plan.createdAt, ok: true }] });
  });
  for (let index = 1; index <= 48; index++) {
    await runInDurableObject(owner(), async (_, state) => {
      const observer = new DotStabilityObservation(state.storage, () => plan.createdAt + index * observationInterval);
      await observer.tick(true); await observer.tick(true);
      expect(observer.status(plan.id).samples).toHaveLength(index + 1);
    });
    if (index % 12 === 0) await abortAllDurableObjects();
  }
  await runInDurableObject(owner(), async (_, state) => {
    const observer = new DotStabilityObservation(state.storage, () => plan.createdAt + observationDuration);
    expect(observer.status(plan.id)).toMatchObject({ state: "completed", elapsedMs: observationDuration, nextSampleAt: null,
      macBridgeUsed: false, messagesSent: 0, realDotConversationsTestedByObservation: false });
    expect(observer.nextDue()).toBeUndefined();
    expect(state.storage.sql.exec("SELECT id FROM outbox").toArray()).toEqual([]);
    const saved = state.storage.sql.exec<{ baseline: string }>("SELECT baseline FROM cloud_stability_runs").one();
    expect(saved.baseline).not.toContain("private fixture"); expect(saved.baseline).not.toContain("mock reply");
  });
});
it.each(["subscription", "gap", "message", "sync"])("stops honestly on %s failure and never resends or keeps sampling", async cause => {
  const plan = await fixture();
  await runInDurableObject(owner(), async (_, state) => {
    let now = plan.createdAt;
    const observer = new DotStabilityObservation(state.storage, () => now); await observer.start(plan, true);
    if (cause === "message") state.storage.sql.exec("UPDATE messages SET reply = 'changed' WHERE id = ?", plan.messages[0]);
    if (cause === "sync") state.storage.sql.exec("UPDATE history_sync_requests SET batch = '[true,[]]' WHERE id = ?", plan.syncs[0]);
    now += observationInterval + (cause === "gap" ? 600_001 : 0);
    await observer.tick(cause !== "subscription");
    const failed = observer.status(plan.id);
    expect(failed.state).toBe("failed");
    expect(failed.reason).toBe(cause === "subscription" ? "subscription_unavailable" : cause === "gap" ? "observation_gap" : "known_record_changed");
    now += observationDuration; await observer.tick(true);
    expect(observer.status(plan.id)).toEqual(failed); expect(observer.nextDue()).toBeUndefined();
    expect(state.storage.sql.exec("SELECT id FROM outbox").toArray()).toEqual([]);
  });
});
it("keeps GET status read-only and identical start idempotent, including concurrent requests", async () => {
  const plan = await fixture();
  await runInDurableObject(owner(), async (_, state) => {
    let now = plan.createdAt;
    const observer = new DotStabilityObservation(state.storage, () => now);
    const results = await Promise.all([observer.start(plan, true), observer.start(plan, true)]);
    expect(results[0]).toEqual(results[1]);
    now += observationInterval;
    for (let index = 0; index < 5; index++) expect(observer.status(plan.id)).toEqual(results[0]);
    expect(await observer.start(plan, false)).toEqual(results[0]);
    await expect(observer.start({ ...plan, createdAt: plan.createdAt + 1 }, true)).rejects.toMatchObject({ code: "request_id_conflict" });
  });
});
it("allows one running observation and rejects unknown, pending, duplicated and unscoped record plans", async () => {
  const plan = await fixture();
  await runInDurableObject(owner(), async (_, state) => {
    const observer = new DotStabilityObservation(state.storage, () => plan.createdAt);
    for (const wrong of [{ ...plan, messages: [crypto.randomUUID()] }, { ...plan, messages: [...plan.messages, ...plan.messages] },
      { ...plan, duration: 0 }, { ...plan, syncs: [] }]) await expect(observer.start(wrong, true)).rejects.toBeDefined();
    await expect(observer.start(plan, false)).rejects.toMatchObject({ code: "dot_not_subscribed" });
    const competing = await Promise.allSettled([observer.start(plan, true), observer.start({ ...plan, id: crypto.randomUUID() }, true)]);
    expect(competing.filter(result => result.status === "fulfilled")).toHaveLength(1);
    expect(state.storage.sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM cloud_stability_runs").one().count).toBe(1);
  });
});
it("integrates with the existing alarm without replacing an earlier subscription deadline", async () => {
  const plan = await fixture(), expiresAt = plan.createdAt + 60_000;
  await runInDurableObject(owner(), async (_, state) => {
    const subscription = { id: "fixture-observer-sub", url: "https://mcp-callback.invalid/events/fixture", secret: "fixture", expiresAt, revision: "fixture" };
    state.storage.sql.exec("INSERT INTO subscriptions VALUES (?, ?, 1)", subscription.id, JSON.stringify(subscription));
  });
  expect(await owner().execute({ kind: "observation_start", input: plan })).toMatchObject({ ok: true, value: { state: "running" } });
  await runInDurableObject(owner(), async (_, state) => {
    expect(await state.storage.getAlarm()).toBe(expiresAt);
    const observation = new DotStabilityObservation(state.storage); expect(observation.nextDue()).toBeGreaterThan(expiresAt);
  });
});
