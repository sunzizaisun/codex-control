import assert from 'node:assert/strict';
import test from 'node:test';
import { firstRoundJournal } from '../lib/dot-first-round-journal.mjs';
import { dotStabilityPlan } from '../lib/dot-stability-plan.mjs';
const thread = '11111111-1111-4111-8111-111111111111';
function fixture() {
  const row = dotStabilityPlan('abcdef12')[0];
  return [
    { stage: 'start', batch: 'abcdef12', thread, newMessages: 6 },
    { stage: 'submit-once', batch: 'abcdef12', thread, id: '00000000-0000-4000-8000-000000000001',
      createdAt: 123, label: row.label, text: row.text, expected: row.expected },
  ];
}
const serialize = rows => rows.map(row => JSON.stringify(row)).join('\n');
test('recovers only the original first ID and exact Unicode command after logged timeout', () => {
  const rows = fixture();
  const result = firstRoundJournal(serialize(rows) + '\nError: qa_reply_timeout\n');
  assert.equal(result.batch, rows[0].batch);
  assert.deepEqual(result.first.command, { id: rows[1].id, thread, text: rows[1].text, createdAt: rows[1].createdAt });
});
test('rejects additional submissions, completed runs and duplicate starts', () => {
  for (const extra of [fixture()[1], fixture()[0], { stage: 'reply-verified' }, { stage: 'completed' }]) {
    assert.throws(() => firstRoundJournal(serialize([...fixture(), extra])), /unexpected_qa_journal_scope/);
  }
});
test('rejects changed thread, batch, original text, expected reply, time and ID', () => {
  for (const [key, value] of [['thread', 'different'], ['batch', '12345678'], ['text', '改动🙂'],
    ['expected', 'forged'], ['createdAt', -1], ['id', '../other']]) {
    const rows = fixture(); rows[1][key] = value;
    assert.throws(() => firstRoundJournal(serialize(rows)));
  }
});
test('rejects malformed or oversized journals instead of guessing', () => {
  for (const raw of ['', '{"stage":invalid}', 'x'.repeat(128 * 1024 + 1)]) assert.throws(() => firstRoundJournal(raw));
});
