// Explicitly bounded production QA only. Six new messages; one intentional
// duplicate of the first payload tests idempotency. No automatic POST retry.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { setTimeout as delay } from 'node:timers/promises';
import { dotReceiptTiming } from './lib/dot-receipt-timing.mjs';
import { dotStabilityPlan } from './lib/dot-stability-plan.mjs';
import { dotStabilityGate, receiptPollDelay } from './lib/dot-stability-gate.mjs';
import { firstRoundJournal } from './lib/dot-first-round-journal.mjs';
import { withBoundedReadRetry } from './lib/dot-read-retry.mjs';
import { qaSettleDelay } from './lib/dot-qa-pacing.mjs';
const args = process.argv.slice(2);
const pacedRun = args.length === 1 && args[0] === '--run-six-qa-rounds-with-settle';
const pacedPlan = args.length === 1 && args[0] === '--plan-six-qa-rounds-with-settle';
const resumePath = args[0] === '--resume-after-first-late-reply' && args.length === 2 ? args[1] : null;
const previous = resumePath ? firstRoundJournal(await readFile(resumePath, 'utf8')) : null;
const batch = previous?.batch ?? randomUUID().slice(0, 8);
const plan = dotStabilityPlan(batch);
if (!resumePath && !pacedRun && !(args.length === 1 && args[0] === '--run-six-qa-rounds')) {
  if (args.length && !pacedPlan) throw Error('invalid_qa_arguments');
  console.log(JSON.stringify({ dryRun: true, newMessages: 6, explicitDuplicateRequests: 1,
    thread: '11111111-1111-4111-8111-111111111111', plan,
    ...(pacedPlan ? { pacing: { beforeRounds: [3, 5], milliseconds: 30000, upstreamIdleGuaranteed: false } } : {}) }, null, 2));
  process.exit(0);
}
const thread = '11111111-1111-4111-8111-111111111111';
const key = process.env.DOT_QA_DEVICE_KEY;
const origin = process.env.DOT_QA_ORIGIN;
assert.ok(key && /^[A-Za-z0-9+/]{43}=$/.test(key), 'explicit_qa_device_key_required');
assert.ok(origin && new URL(origin).protocol === 'https:' && new URL(origin).origin === origin, 'explicit_qa_origin_required');
async function request(path, body) {
  return withBoundedReadRetry(body ? 'POST' : 'GET', async () => {
    const r = await fetch(origin + path, {
      redirect: 'error', signal: AbortSignal.timeout(15000),
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      ...(body ? { method: 'POST', body: JSON.stringify(body) } : {}),
    });
    assert.ok(r.ok, `qa_http_${r.status}`);
    return r.json();
  });
}
function exact(row, round) {
  assert.equal(row.id, round.command.id, 'wrong_receipt');
  assert.equal(row.thread, thread, 'wrong_thread');
  assert.equal(row.text, round.text, 'input_changed');
  assert.equal(row.createdAt, round.command.createdAt, 'creation_time_changed');
  assert.equal(row.state, 'replied', 'reply_missing');
  assert.equal(row.reply, round.expected, 'reply_mismatch');
}
function proofFor(receipt, round, late = false) {
  return { stage: 'reply-verified', batch, label: round.label, id: receipt.id,
    createdAt: receipt.createdAt, repliedAt: receipt.repliedAt, timing: receipt.timing,
    exactInput: true, exactReply: true, ...dotReceiptTiming(receipt),
    callbackAttempts: receipt.timing?.attempts, reply: receipt.reply,
    ...(late ? { recoveredAfterClientTimeout: true } : {}) };
}
async function submit(row) {
  const round = { ...row, command: { id: randomUUID(), thread, text: row.text, createdAt: Date.now() } };
  // Emit the durable ID before attempting transmission. On uncertain network
  // failures stop and inspect this ID; never silently repost or generate a retry.
  console.log(JSON.stringify({ stage: 'submit-once', batch, label: row.label, ...round.command, expected: row.expected }));
  await request('/v2/messages', round.command);
  return round;
}
async function waitReply(round) {
  const started = Date.now();
  // Bound wall-clock waiting even when individual receipt requests are slow.
  // Only GETs are repeated. Message submission is never retried here.
  while (Date.now() - started < 180000) {
    const receipt = await request('/v2/receipts/' + round.command.id);
    assert.equal(receipt.id, round.command.id);
    assert.equal(receipt.text, round.text);
    assert.ok(!['delivery_failed', 'expired'].includes(receipt.state), receipt.state);
    if (receipt.state === 'replied') {
      exact(receipt, round);
      const proof = proofFor(receipt, round);
      console.log(JSON.stringify(proof));
      return { ...round, receipt, proof };
    }
    const remaining = 180000 - (Date.now() - started);
    if (remaining > 0) await delay(Math.min(remaining, receiptPollDelay(Date.now() - started)));
  }
  throw new Error(`qa_reply_timeout:${round.command.id}`);
}
const status = await request('/v2/status');
assert.equal(status.subscribed, true, 'subscription_missing');
console.log(JSON.stringify({ stage: previous ? 'resume' : 'start', batch, thread,
  newMessages: previous ? 5 : 6, nativeDevicesTested: false,
  ...(pacedRun ? { pacing: { beforeRounds: [3, 5], milliseconds: 30000, upstreamIdleGuaranteed: false } } : {}) }));
async function settleBefore(roundIndex) {
  const ms = qaSettleDelay(roundIndex, pacedRun);
  if (!ms) return;
  const startedAt = Date.now();
  console.log(JSON.stringify({ stage: 'settle-start', batch, beforeRound: roundIndex + 1, startedAt, milliseconds: ms }));
  await delay(ms);
  console.log(JSON.stringify({ stage: 'settle-complete', batch, beforeRound: roundIndex + 1, startedAt, completedAt: Date.now() }));
}
const completed = [];
if (previous) {
  // No POST for the prior message. Unknown/pending/conflicting receipt stops
  // recovery before any remaining message is transmitted.
  const receipt = await request('/v2/receipts/' + previous.first.command.id);
  exact(receipt, previous.first);
  const proof = proofFor(receipt, previous.first, true);
  console.log(JSON.stringify(proof));
  completed.push({ ...previous.first, receipt, proof });
}
for (const [index, row] of plan.slice(previous ? 1 : 0, 4).entries()) {
  await settleBefore(index + (previous ? 1 : 0));
  completed.push(await waitReply(await submit(row)));
}
// This duplicate request is deliberate QA, not a response to a failed send.
const first = completed[0];
const duplicate = await request('/v2/messages', first.command);
exact(duplicate, first);
assert.equal(duplicate.repliedAt, first.receipt.repliedAt, 'duplicate_created_new_reply');
assert.deepEqual(duplicate.timing, first.receipt.timing, 'duplicate_redelivered_event');
console.log(JSON.stringify({ stage: 'duplicate-verified', batch, id: first.command.id }));
await settleBefore(4);
const burst = await Promise.all(plan.slice(4).map(submit));
completed.push(...await Promise.all(burst.map(waitReply)));
const history = await request('/v2/threads/' + thread + '/messages');
for (const round of completed) {
  const matches = history.messages.filter(row => row.id === round.command.id);
  assert.equal(matches.length, 1, 'duplicate_or_missing_history');
  exact(matches[0], round);
}
assert.equal((await request('/v2/status')).subscribed, true, 'subscription_lost');
const times = completed.map(row => row.proof.serverSeconds);
assert.ok(times.every(time => Number.isFinite(time) && time >= 0), 'invalid_server_timing');
const sorted = [...times].sort((a, b) => a - b);
console.log(JSON.stringify({ stage: 'completed', batch, rounds: completed.map(row => row.proof),
  passed: completed.length, duplicateSafe: true, sharedHistoryExact: true,
  latency: { min: sorted[0], max: sorted.at(-1), median: (sorted[2] + sorted[3]) / 2,
    mean: times.reduce((a, b) => a + b, 0) / times.length },
  installationGate: dotStabilityGate(times),
  ...(pacedRun ? { pacing: { beforeRounds: [3, 5], milliseconds: 30000, upstreamIdleGuaranteed: false,
    intentionalSpacingExcludedFromEachReceiptLatency: true } } : {}),
  nativeDevicesTested: false, officialUIVerified: false, longRunningReliabilityEstablished: false }, null, 2));
