// All replies here are isolated fixtures, not evidence of a real dot reply.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { dotCloudOrigin, dotCloudRequest, portableDotPlan, runPortableDotAcceptance } from '../lib/dot-portable-acceptance.mjs';

function fixture(options = {}) {
  const batch = 'aabb0011', plan = portableDotPlan(batch), calls = [], events = [], commands = [];
  let time = 100000, sequence = 0;
  const thread = '11111111-2222-4333-8444-555555555555';
  const uuid = () => `aaaaaaaa-bbbb-4ccc-8ddd-${String(++sequence).padStart(12, '0')}`;
  const receipt = command => ({ ...command, thread, state: 'replied', repliedAt: command.createdAt + 10,
    reply: plan[commands.indexOf(command)].expected });
  const request = async (path, body) => {
    calls.push({ path, body });
    if (path === '/v2/status') return { transport: 'mcp-events', subscribed: options.subscribed ?? true, expiresAt: time + 1000000 };
    if (path === '/v2/messages') {
      commands.push(body);
      if (options.lostAck) throw Error('network_failure');
      return { ...body, thread, state: 'queued' };
    }
    if (path.startsWith('/v2/receipts/')) {
      const command = commands.find(row => row.id === path.split('/').at(-1));
      if (options.timeout) return { ...command, thread, state: 'delivered' };
      return { ...receipt(command), ...(options.changedInput ? { text: 'changed' } : {}), ...(options.wrongReply ? { reply: 'wrong' } : {}) };
    }
    if (path === '/v3/sync') return { id: body.id, state: 'pending' };
    if (path.startsWith('/v3/sync/')) return { id: path.split('/').at(-1), state: 'completed', messages: [], hiddenMessageIDs: [] };
    if (path === '/v3/messages') {
      const messages = commands.flatMap(command => [
        { id: command.id + '.user', role: 'user', text: command.text },
        { id: command.id + '.reply', role: 'assistant', text: receipt(command).reply },
      ]);
      if (options.duplicate) messages.push(messages[0]);
      return { messages };
    }
    throw Error('unexpected_route');
  };
  return { calls, commands, events,
    run: () => runPortableDotAcceptance({ request, batch, uuid, now: () => time,
      sleep: async ms => { time += ms; }, emit: event => events.push(event), timeoutMs: 100 }) };
}

test('portable plan recall questions do not include the answer', () => {
  const plan = portableDotPlan('aabb0011');
  assert.equal(plan.length, 4);
  for (const index of [1, 3]) assert.ok(!plan[index].text.includes(plan[index].expected));
});
test('portable fixture completes four rounds with one control POST and a single bounded history GET', async () => {
  const f = fixture(), result = await f.run();
  assert.equal(result.passed, 4);
  assert.equal(result.macBridgeUsed, false);
  assert.equal(result.nativeUIVerified, false);
  assert.equal(f.commands.length, 4);
  assert.ok(f.commands.every(row => row.shared === true && row.thread === undefined));
  assert.equal(f.calls.filter(row => row.path === '/v3/messages').length, 1);
  assert.equal(f.calls.filter(row => row.path === '/v3/sync' && row.body).length, 1);
  assert.equal(f.events.filter(row => row.stage === 'submit-once').length, 4);
});
test('portable quota or subscription failure sends nothing', async () => {
  const f = fixture({ subscribed: false });
  await assert.rejects(f.run, /subscription_missing/);
  assert.equal(f.commands.length, 0);
  assert.equal(f.calls.length, 1);
});
for (const scenario of ['lostAck', 'timeout', 'changedInput', 'wrongReply']) {
  test(`portable ${scenario} stops before further sends and never retries POST`, async () => {
    const f = fixture({ [scenario]: true });
    await assert.rejects(f.run);
    assert.equal(f.commands.length, 1);
    assert.equal(f.calls.filter(row => row.body).length, 1);
    assert.equal(f.events.filter(row => row.stage === 'submit-once').length, 1);
  });
}
test('portable duplicate timeline does not pass acceptance', async () => {
  const f = fixture({ duplicate: true });
  await assert.rejects(f.run, /duplicate_message_ids/);
});
test('portable transport only uses original cloud and rejects arbitrary endpoints', async () => {
  const calls = [], key = 'a'.repeat(43) + '=';
  const request = dotCloudRequest(key, async (url, options) => {
    calls.push({ url, options });
    return Response.json({ subscribed: true });
  });
  await request('/v2/status');
  assert.equal(calls[0].url, dotCloudOrigin + '/v2/status');
  assert.equal(calls[0].options.redirect, 'error');
  for (const path of ['/admin/pending', '/mcp', '/v3/messages?cursor=older', 'https://other.invalid']) {
    await assert.rejects(() => request(path));
  }
  assert.equal(calls.length, 1);
});
test('portable transport does not retry a lost POST or expose an upstream response body', async () => {
  let calls = 0;
  const request = dotCloudRequest('a'.repeat(43) + '=', async () => {
    calls++;
    return new Response('PRIVATE upstream content', { status: 503 });
  });
  await assert.rejects(() => request('/v2/messages', {}), /^Error: qa_http_503:gateway_error$/);
  assert.equal(calls, 1);
});
