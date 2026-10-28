import assert from 'node:assert/strict';
import test from 'node:test';
import { dotStabilityPlan } from '../lib/dot-stability-plan.mjs';
test('six bounded tests, with answers omitted from both recall prompts', () => {
  const plan = dotStabilityPlan('abcdef12');
  assert.equal(plan.length, 6);
  assert.equal(new Set(plan.map(row => row.label)).size, 6);
  assert.equal(plan[1].expected, plan[0].expected);
  assert.equal(plan[3].expected, plan[2].expected);
  assert.notEqual(plan[0].expected, plan[2].expected);
  for (const index of [1, 3]) assert.ok(!plan[index].text.includes(plan[index].expected));
  assert.ok(plan.every(row => row.text.length < 4000 && row.text.includes('不要执行命令或调用其他插件')));
  assert.notEqual(plan[4].expected, plan[5].expected);
});
test('rejects unbounded batch labels', () => {
  for (const label of ['', '../other', 'x'.repeat(4000), 'abcd1234\n']) {
    assert.throws(() => dotStabilityPlan(label), /invalid_test_batch/);
  }
});
