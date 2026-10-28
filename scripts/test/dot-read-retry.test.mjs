import assert from 'node:assert/strict';
import test from 'node:test';
import { withBoundedReadRetry } from '../lib/dot-read-retry.mjs';
const reset = () => new TypeError('fetch failed', { cause: { code: 'ECONNRESET' } });
test('only a transient GET read can recover, with two bounded backoff delays', async () => {
  let calls = 0; const pauses = [];
  const result = await withBoundedReadRetry('GET', async () => { if (++calls < 3) throw reset(); return { id: 'same-receipt' }; }, async ms => pauses.push(ms));
  assert.deepEqual(result, { id: 'same-receipt' }); assert.equal(calls, 3); assert.deepEqual(pauses, [500, 1000]);
});
test('never retries uncertain POST/PUT/DELETE writes even on a connection reset', async () => {
  for (const method of ['POST', 'PUT', 'DELETE']) {
    let calls = 0;
    await assert.rejects(withBoundedReadRetry(method, async () => { calls++; throw reset(); }, async () => assert.fail('write retry')));
    assert.equal(calls, 1);
  }
});
test('stops repeated transport failures and never retries authentication, quota or parse errors', async () => {
  let calls = 0;
  await assert.rejects(withBoundedReadRetry('GET', async () => { calls++; throw reset(); }, async () => {}));
  assert.equal(calls, 3);
  for (const error of [new Error('qa_http_401'), new Error('qa_http_503'), new SyntaxError('invalid_json')]) {
    let reads = 0;
    await assert.rejects(withBoundedReadRetry('GET', async () => { reads++; throw error; }, async () => assert.fail('provider retry')));
    assert.equal(reads, 1);
  }
});
