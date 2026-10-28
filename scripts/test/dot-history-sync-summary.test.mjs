import test from 'node:test';
import assert from 'node:assert/strict';
import { historySyncSummary } from '../lib/dot-history-sync-summary.mjs';

test('enriched history receipts expose batch counts without private bodies or unknown fields', () => {
  const summary = historySyncSummary({ id: '24e49a02-5cee-49d0-a8e8-9e1b923f84ea', state: 'completed', imported: 2,
    messages: [{ id: 'official.one', role: 'user', text: 'private body' }, { id: 'official.two', text: 'private reply' }],
    hiddenMessageIDs: ['official.mirror'], privateToken: 'sensitive', timing: { acceptedAt: 1, privateBody: 'sensitive' } });
  assert.deepEqual(summary.batch, { visible: 2, hidden: 1, bounded: true, unique: true, onlyOfficialIDs: true });
  assert.deepEqual(summary.timing, { acceptedAt: 1 });
  for (const forbidden of ['private body', 'private reply', 'sensitive', 'official.one', 'official.mirror']) assert.ok(!JSON.stringify(summary).includes(forbidden));
});
test('older metadata receipts remain compatible and duplicate batch IDs are not called unique', () => {
  assert.deepEqual(historySyncSummary({ state: 'pending', expiresAt: 100, batch: 'private' }), { state: 'pending', expiresAt: 100 });
  assert.equal(historySyncSummary({ messages: [{ id: 'official.a' }], hiddenMessageIDs: ['official.a'] }).batch.unique, false);
  assert.equal(historySyncSummary({ hiddenMessageIDs: ['other.user'] }).batch.onlyOfficialIDs, false);
  assert.equal(historySyncSummary({ hiddenMessageIDs: Array.from({ length: 31 }, (_, i) => `official.${i}`) }).batch.bounded, false);
});
test('sync diagnostics expose only allowlisted timing and safe machine errors', () => {
  const summary = historySyncSummary({ timing: { readAt: 3, mcpReceivedAt: 1, mcpAuthorizedAt: 2, token: 'secret' },
    historyImport: { startedAt: 4, attempts: 2, lastFailedAt: 5, lastError: 'history_conflict', text: 'private body' } });
  assert.deepEqual(summary.timing, { readAt: 3, mcpReceivedAt: 1, mcpAuthorizedAt: 2 });
  assert.deepEqual(summary.historyImport, { startedAt: 4, attempts: 2, lastFailedAt: 5, lastError: 'history_conflict' });
  assert.ok(!JSON.stringify(summary).includes('secret')); assert.ok(!JSON.stringify(summary).includes('private body'));
  assert.deepEqual(historySyncSummary({ historyImport: { attempts: -1, startedAt: NaN, lastError: 'private text https://secret' } }).historyImport, {});
});
