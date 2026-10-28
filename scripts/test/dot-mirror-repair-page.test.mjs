import assert from 'node:assert/strict';
import test from 'node:test';
import { summarizeAuthorizedPage } from '../verify-dot-mirror-repair-page.mjs';

const tests = Array.from({ length: 8 }, (_, index) => ({ id: `test-${index}`, text: `原文${index}🙂`, expected: '相同但独立的回复🦦' }));
const official = { question: '官方接续问题', actualReply: tests[0].expected, preRepairExactReplyMatches: { officialID: 'answer' } };
function fixture() {
  return { capturedAt: 99, nextCursor: 'must-not-be-followed', messages: [
    ...tests.flatMap(item => [
      { id: `${item.id}.user`, role: 'user', text: item.text, sentAt: 1 },
      { id: `${item.id}.reply`, role: 'assistant', text: item.expected, sentAt: 2 },
    ]),
    { id: 'official.question', role: 'user', text: official.question, sentAt: 3 },
    { id: 'official.answer', role: 'assistant', text: official.actualReply, sentAt: 4 },
    { id: 'private-other-id', role: 'user', text: 'PRIVATE_UNRELATED_BODY', sentAt: 5 },
  ] };
}
test('counts exact pairs without collapsing independent identical replies or leaking other records', () => {
  const result = summarizeAuthorizedPage(fixture(), tests, official);
  assert.equal(result.tests.length, 8);
  assert.ok(result.tests.every(row => row.inputCount === 1 && row.exactInputCount === 1 && row.replyCount === 1 && row.exactReplyCount === 1 && row.visibleMirrorCount === 0));
  assert.equal(result.officialContext.questionCount, 1);
  assert.equal(result.officialContext.replyCount, 1);
  for (const secret of ['PRIVATE_UNRELATED_BODY', 'private-other-id', official.question, tests[0].expected, 'must-not-be-followed']) {
    assert.ok(!JSON.stringify(result).includes(secret));
  }
});
test('detects semantic mirror remaining under a different official ID', () => {
  const page = fixture();
  page.messages.push({ id: 'official.mirror', role: 'assistant', text: `来自手机／手表 用户：${tests[0].text} dot：${tests[0].expected} 同步编号：${tests[0].id}`, sentAt: 6 });
  assert.equal(summarizeAuthorizedPage(page, tests, official).tests[0].visibleMirrorCount, 1);
});
test('detects exact-input changes and duplicate IDs', () => {
  const page = fixture();
  page.messages[0].text += 'changed';
  page.messages.push({ ...page.messages[1] });
  const result = summarizeAuthorizedPage(page, tests, official);
  assert.equal(result.tests[0].exactInputCount, 0);
  assert.equal(result.tests[0].replyCount, 2);
  assert.equal(result.duplicatePageIDCount, 1);
});
test('an absent old test stays absent rather than being inferred from identical text', () => {
  const page = fixture();
  page.messages = page.messages.filter(row => row.id !== `${tests[0].id}.reply`);
  assert.equal(summarizeAuthorizedPage(page, tests, official).tests[0].exactReplyCount, 0);
});
test('rejects over-30 pages and malformed input without including body in error', () => {
  const page = fixture();
  while (page.messages.length <= 30) page.messages.push(page.messages[0]);
  assert.throws(() => summarizeAuthorizedPage(page, tests, official), /^Error: invalid_bounded_page$/);
  assert.throws(() => summarizeAuthorizedPage(fixture(), tests.slice(1), official), /^Error: invalid_test_scope$/);
  const malformed = fixture();
  malformed.messages[0].sentAt = 'PRIVATE_UNRELATED_BODY';
  assert.throws(() => summarizeAuthorizedPage(malformed, tests, official), /^Error: invalid_page_row$/);
});
test('the explicit six-round mode is bounded separately and does not weaken the eight-round default', () => {
  const six = tests.slice(0, 6);
  assert.equal(summarizeAuthorizedPage(fixture(), six, official, 6).tests.length, 6);
  assert.throws(() => summarizeAuthorizedPage(fixture(), six, official), /invalid_test_scope/);
  for (const count of [0, 5, 7, 30]) assert.throws(() => summarizeAuthorizedPage(fixture(), tests.slice(0, count), official, count), /invalid_test_scope/);
});
