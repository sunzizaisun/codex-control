import test from 'node:test';
import assert from 'node:assert/strict';
import { dotReleaseChecks, dotStabilityGate, receiptPollDelay } from '../lib/dot-stability-gate.mjs';

test('fast timings alone never authorize installation', () => {
  const result = dotStabilityGate([10, 20, 25, 25, 40, 45]);
  assert.equal(result.passed, false);
  assert.deepEqual(result.missing, dotReleaseChecks);
  assert.equal(dotStabilityGate([1, 2, 3]).passed, false);
  assert.equal(dotStabilityGate([1, 2, 3, 4, 5, NaN]).passed, false);
  assert.equal(dotStabilityGate([1, 2, 3, 4, 5, -1]).passed, false);
});

test('accepted high latency is informational but every reliability gate remains required', () => {
  const evidence = Object.fromEntries(dotReleaseChecks.map(key => [key, true]));
  const slow = [20, 30, 40, 60, 180, 425];
  const result = dotStabilityGate(slow, evidence);
  assert.equal(result.passed, true);
  assert.equal(result.max, 425);
  assert.equal(result.latencyInformationalOnly, true);
  assert.equal(result.physicalInstallationAutomaticallyAuthorized, false);
  for (const key of dotReleaseChecks) {
    const failed = dotStabilityGate(slow, { ...evidence, [key]: false });
    assert.equal(failed.passed, false);
    assert.deepEqual(failed.missing, [key]);
  }
  assert.equal(dotStabilityGate(slow, { ...evidence, deduplication: 'true' }).passed, false);
  for (const invalid of [null, false, [], 'all passed']) {
    assert.deepEqual(dotStabilityGate(slow, invalid), { passed: false, reason: 'invalid_release_evidence' });
  }
  assert.equal(dotStabilityGate(null, evidence).passed, false);
});

test('receipt reads slow down after the foreground fast window', () => {
  assert.equal(receiptPollDelay(0), 1000);
  assert.equal(receiptPollDelay(89999), 1000);
  assert.equal(receiptPollDelay(90000), 3000);
});
