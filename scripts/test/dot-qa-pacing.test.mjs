import assert from 'node:assert/strict';
import test from 'node:test';
import { spawnSync } from 'node:child_process';
import { qaSettleDelay } from '../lib/dot-qa-pacing.mjs';

test('default QA has no added spacing', () => {
  assert.deepEqual(Array.from({ length: 6 }, (_, i) => qaSettleDelay(i)), [0, 0, 0, 0, 0, 0]);
});
test('diagnostic spacing only precedes rounds three and five, preserving immediate follow-ups and the burst pair', () => {
  assert.deepEqual(Array.from({ length: 6 }, (_, i) => qaSettleDelay(i, true)), [0, 0, 30000, 0, 30000, 0]);
});
test('invalid scope or nonboolean enabling is rejected', () => {
  for (const i of [-1, 6, 0.5, NaN, '2']) assert.throws(() => qaSettleDelay(i, true), /invalid_qa_pacing/);
  for (const enabled of [1, 'true', null]) assert.throws(() => qaSettleDelay(2, enabled), /invalid_qa_pacing/);
});
test('planning mode exits before reading credentials or performing live requests', () => {
  const result = spawnSync(process.execPath, ['scripts/run-dot-stability.mjs', '--plan-six-qa-rounds-with-settle'], {
    cwd: new URL('../../', import.meta.url), encoding: 'utf8', timeout: 10000,
  });
  assert.equal(result.status, 0, result.stderr);
  const output = JSON.parse(result.stdout);
  assert.equal(output.dryRun, true);
  assert.equal(output.newMessages, 6);
  assert.equal(output.plan.length, 6);
  assert.deepEqual(output.pacing.beforeRounds, [3, 5]);
  assert.equal(output.pacing.upstreamIdleGuaranteed, false);
});
