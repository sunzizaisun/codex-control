import { dotStabilityPlan } from './dot-stability-plan.mjs';

// A deliberately narrow recovery: exactly one known first-round submission.
// The caller must verify its real receipt before sending rounds two to six.
export function firstRoundJournal(raw) {
  if (typeof raw !== 'string' || Buffer.byteLength(raw, 'utf8') > 128 * 1024) throw Error('invalid_qa_journal');
  const entries = raw.split('\n').filter(line => line.startsWith('{"stage":')).map(line => {
    try { return JSON.parse(line); } catch { throw Error('invalid_qa_journal'); }
  });
  const starts = entries.filter(row => row.stage === 'start');
  const submissions = entries.filter(row => row.stage === 'submit-once');
  if (starts.length !== 1 || submissions.length !== 1 || entries.some(row => !['start', 'submit-once'].includes(row.stage))) throw Error('unexpected_qa_journal_scope');
  const start = starts[0], first = submissions[0];
  const thread = '11111111-1111-4111-8111-111111111111';
  if (start.thread !== thread || first.thread !== thread || start.newMessages !== 6 || first.batch !== start.batch) throw Error('wrong_qa_journal_scope');
  const expected = dotStabilityPlan(start.batch)[0];
  if (first.label !== expected.label || first.text !== expected.text || first.expected !== expected.expected ||
      !/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(first.id ?? '') ||
      !Number.isSafeInteger(first.createdAt) || first.createdAt <= 0) throw Error('invalid_first_round_evidence');
  return { batch: start.batch, first: { ...expected, command: {
    id: first.id, thread, text: first.text, createdAt: first.createdAt,
  } } };
}
