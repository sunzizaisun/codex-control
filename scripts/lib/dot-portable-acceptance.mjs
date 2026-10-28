import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

export const dotCloudOrigin = process.env.DOT_QA_ORIGIN || 'https://dot-inbox.example.com';

export function portableDotPlan(batch) {
  assert.match(batch, /^[a-f0-9]{8}$/);
  const first = `山雀-${batch}🐦`, second = `白桦-${batch}🍁`;
  const instruction = '只用伴随回复工具回传，不执行命令或调用其他插件。';
  return [
    { label: 'seed', text: `云端验收1[${batch}]：请记住短语“${first}”，只回复完整短语。${instruction}`, expected: first },
    { label: 'recall', text: `云端验收2[${batch}]：本批云端验收1的完整短语是什么？只回复完整短语。${instruction}`, expected: first },
    { label: 'replace', text: `云端验收3[${batch}]：将本批短语更新为“${second}”，只回复完整新短语。${instruction}`, expected: second },
    { label: 'recall-after-reconnect', text: `云端验收4[${batch}]：本批云端验收3更新后的完整短语是什么？只回复完整短语。${instruction}`, expected: second },
  ];
}

// Runs on Node in any hosted runner. No Apple frameworks, local bridge,
// root relay secret, OAuth credentials or MCP reply capability are needed.
export function dotCloudRequest(key, fetcher = fetch) {
  const origin = new URL(dotCloudOrigin);
  assert.ok(origin.protocol === 'https:' && origin.origin === dotCloudOrigin && !origin.username && !origin.password, 'invalid_qa_origin');
  assert.ok(typeof key === 'string' && /^[A-Za-z0-9+/]{43}=$/.test(key), 'missing_device_key');
  return async (path, body) => {
    assert.match(path, /^\/v[23]\/(?:status|messages|receipts\/[a-f0-9-]{36}|sync(?:\/[a-f0-9-]{36})?)$/);
    const response = await fetcher(dotCloudOrigin + path, {
      redirect: 'error', signal: AbortSignal.timeout(15000),
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      ...(body === undefined ? {} : { method: 'POST', body: JSON.stringify(body) }),
    });
    if (!response.ok) {
      // Never expose arbitrary upstream response text or exceptions.
      const failure = await response.json().catch(() => null);
      const code = /^[a-z0-9_]{1,80}$/.test(failure?.error ?? '') ? failure.error : 'gateway_error';
      throw Error(`qa_http_${response.status}:${code}`);
    }
    return response.json();
  };
}

function verifyReceipt(receipt, command, thread) {
  assert.equal(receipt.id, command.id, 'wrong_receipt');
  assert.equal(receipt.text, command.text, 'input_changed');
  assert.equal(receipt.createdAt, command.createdAt, 'creation_time_changed');
  assert.match(receipt.thread ?? '', /^[a-f0-9-]{36}$/);
  if (thread) assert.equal(receipt.thread, thread, 'conversation_changed');
  assert.ok(['queued', 'delivered', 'replied'].includes(receipt.state), 'delivery_failed');
}

export async function runPortableDotAcceptance({ request, emit, sleep, now = Date.now,
  uuid = randomUUID, batch = randomUUID().slice(0, 8), timeoutMs = 180000 }) {
  assert.ok(timeoutMs > 0 && timeoutMs <= 300000, 'invalid_deadline');
  const status = await request('/v2/status'); // exactly one preflight
  assert.equal(status.transport, 'mcp-events', 'wrong_route');
  assert.equal(status.subscribed, true, 'subscription_missing');
  assert.ok(Number.isFinite(status.expiresAt) && status.expiresAt > now(), 'subscription_expired');
  emit({ stage: 'start', batch, newMessageLimit: 4, officialTextLimit: 30,
    macBridgeUsed: false, executionHost: 'portable-node' });
  const completed = [];
  let thread;
  for (const row of portableDotPlan(batch)) {
    const command = { id: uuid(), text: row.text, createdAt: now(), shared: true };
    // Save before the ONE write. An uncertain write stops the batch. Recovery
    // uses these IDs with GET; rerunning the command starts a new batch.
    emit({ stage: 'submit-once', batch, label: row.label, command, expected: row.expected });
    verifyReceipt(await request('/v2/messages', command), command, thread);
    const started = now();
    let receipt;
    while (now() - started < timeoutMs) {
      receipt = await request('/v2/receipts/' + command.id);
      verifyReceipt(receipt, command, thread);
      thread ??= receipt.thread;
      if (receipt.state === 'replied') break;
      await sleep(Math.min(10000, timeoutMs - (now() - started)));
    }
    assert.equal(receipt?.state, 'replied', `reply_timeout:${command.id}`);
    assert.equal(receipt.reply, row.expected, 'reply_mismatch');
    assert.ok(Number.isFinite(receipt.repliedAt) && receipt.repliedAt >= command.createdAt, 'invalid_reply_time');
    const proof = { id: command.id, label: row.label, exactInput: true, exactReply: true,
      createdAt: command.createdAt, repliedAt: receipt.repliedAt,
      seconds: (receipt.repliedAt - command.createdAt) / 1000, timing: receipt.timing };
    completed.push({ command, expected: row.expected, proof });
    emit({ stage: 'reply-verified', batch, ...proof });
    // Each GET is a fresh request; no persistent local session/bridge holds
    // the context. This is NOT a physical device radio/background test.
  }
  // Single explicit control event, then GET-only recovery. Never answer this
  // event ourselves. Only the real dot can import official room history.
  const syncCommand = { id: uuid(), createdAt: now() };
  emit({ stage: 'sync-submit-once', batch, ...syncCommand });
  let sync = await request('/v3/sync', syncCommand);
  assert.match(sync.id ?? '', /^[a-f0-9-]{36}$/);
  const syncID = sync.id, syncStarted = now();
  while (['pending', 'delayed'].includes(sync.state) && now() - syncStarted < timeoutMs) {
    await sleep(Math.min(10000, timeoutMs - (now() - syncStarted)));
    sync = await request('/v3/sync/' + syncID);
    assert.equal(sync.id, syncID, 'wrong_sync_receipt');
  }
  assert.equal(sync.state, 'completed', 'history_sync_not_completed');
  assert.ok((sync.messages?.length ?? 0) + (sync.hiddenMessageIDs?.length ?? 0) <= 30, 'history_scope_exceeded');
  emit({ stage: 'history-sync-verified', batch, id: syncID,
    imported: sync.imported, duplicates: sync.duplicates, mirrored: sync.mirrored });
  const page = await request('/v3/messages'); // ONE latest page, never paginate
  assert.ok(Array.isArray(page.messages) && page.messages.length <= 30, 'history_scope_exceeded');
  assert.equal(new Set(page.messages.map(row => row.id)).size, page.messages.length, 'duplicate_message_ids');
  for (const { command, expected } of completed) {
    const users = page.messages.filter(row => row.id === command.id + '.user');
    const replies = page.messages.filter(row => row.id === command.id + '.reply');
    assert.equal(users.length, 1, 'missing_or_duplicate_input');
    assert.equal(replies.length, 1, 'missing_or_duplicate_reply');
    assert.equal(users[0].text, command.text, 'history_input_changed');
    assert.equal(replies[0].text, expected, 'history_reply_changed');
    assert.ok(!page.messages.some(row => row.id.startsWith('official.') && row.text.includes('同步编号：' + command.id)), 'visible_duplicate_mirror');
  }
  const result = { stage: 'completed', batch, passed: completed.length, sharedThread: thread,
    exactHistory: true, duplicateIDs: 0, macBridgeUsed: false,
    nativeUIVerified: false, physicalDevicesTested: false, longRunningReliabilityEstablished: false,
    rounds: completed.map(row => row.proof) };
  emit(result);
  return result;
}
