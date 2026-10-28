import assert from 'node:assert/strict';
import test from 'node:test';
import { dotReceiptTiming } from '../lib/dot-receipt-timing.mjs';

test('splits a completed receipt without attributing provider wait to network', () => {
  const result = dotReceiptTiming({ timing: {
    acceptedAt: 1000, dispatchedAt: 1040, acknowledgedAt: 2000, readAt: 32000,
  }, repliedAt: 37000 });
  assert.deepEqual(result, { queueSeconds: 0.04, callbackSeconds: 0.96,
    afterCallbackToReadSeconds: 30, readToReplySeconds: 5, serverSeconds: 36 });
});
test('pending and missing timestamps are unknown, not zero', () => {
  assert.deepEqual(dotReceiptTiming({ timing: { acceptedAt: 1000, dispatchedAt: 1040 } }), {
    queueSeconds: 0.04, callbackSeconds: null, afterCallbackToReadSeconds: null,
    readToReplySeconds: null, serverSeconds: null,
  });
  assert.ok(Object.values(dotReceiptTiming({})).every(value => value === null));
});
test('rejects malformed and reversed timestamps rather than hiding them', () => {
  for (const bad of [null, undefined, '1000', NaN, Infinity, -1]) {
    assert.equal(dotReceiptTiming({ timing: { acceptedAt: bad }, repliedAt: 2000 }).serverSeconds, null);
  }
  assert.equal(dotReceiptTiming({ timing: { acceptedAt: 2000 }, repliedAt: 1000 }).serverSeconds, null);
});
test('zero-duration phases remain valid', () => {
  assert.deepEqual(dotReceiptTiming({ timing: {
    acceptedAt: 0, dispatchedAt: 0, acknowledgedAt: 0, readAt: 0,
  }, repliedAt: 0 }), { queueSeconds: 0, callbackSeconds: 0,
    afterCallbackToReadSeconds: 0, readToReplySeconds: 0, serverSeconds: 0 });
});
test('new trusted ingress timing separates pre-request delay from authentication and tool dispatch', () => {
  const result = dotReceiptTiming({ timing: { acceptedAt: 1000, dispatchedAt: 1040,
    acknowledgedAt: 2000, mcpReceivedAt: 222000, mcpAuthorizedAt: 222050, readAt: 222080 }, repliedAt: 228000 });
  assert.equal(result.afterCallbackToReadSeconds, 220.08);
  assert.equal(result.afterCallbackToMCPIngressSeconds, 220);
  assert.equal(result.mcpAuthorizationSeconds, 0.05);
  assert.equal(result.mcpAuthorizedToReadSeconds, 0.03);
  assert.equal(result.readToReplySeconds, 5.92);
});
test('partial or reversed ingress timing stays unknown without zero-clamping or backfilling old samples', () => {
  const partial = dotReceiptTiming({ timing: { acknowledgedAt: 2000, mcpReceivedAt: 1000, readAt: 4000 } });
  assert.equal(partial.afterCallbackToMCPIngressSeconds, null);
  assert.equal(partial.mcpAuthorizationSeconds, null);
  assert.equal(partial.mcpAuthorizedToReadSeconds, null);
  assert.equal(partial.afterCallbackToReadSeconds, 2);
  assert.equal(Object.hasOwn(dotReceiptTiming({ timing: { readAt: 4000 } }), 'mcpAuthorizationSeconds'), false);
});
