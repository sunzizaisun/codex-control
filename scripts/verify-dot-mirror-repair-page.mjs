// Opt-in, one-page read only. Never follows a cursor, sends a message, or logs
// raw responses. Output contains only authorized test IDs, counts and times.
import { createHmac } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { dotStabilityPlan } from './lib/dot-stability-plan.mjs';

export function summarizeAuthorizedPage(page, tests, official, expectedCount = 8) {
  if (!Array.isArray(page?.messages) || page.messages.length > 30 ||
      !Number.isSafeInteger(page.capturedAt)) throw Error('invalid_bounded_page');
  if (![6, 8].includes(expectedCount) || tests.length !== expectedCount || new Set(tests.map(t => t.id)).size !== expectedCount) throw Error('invalid_test_scope');
  for (const row of page.messages) {
    if (typeof row.id !== 'string' || !['user', 'assistant'].includes(row.role) ||
        typeof row.text !== 'string' || !Number.isSafeInteger(row.sentAt)) throw Error('invalid_page_row');
  }
  const rows = page.messages;
  const match = (id, role, text) => rows.filter(row => row.id === id && row.role === role && row.text === text);
  return {
    capturedAt: page.capturedAt,
    pageRecordCount: rows.length,
    duplicatePageIDCount: rows.length - new Set(rows.map(row => row.id)).size,
    tests: tests.map(test => {
      const input = rows.filter(row => row.id === `${test.id}.user`);
      const reply = rows.filter(row => row.id === `${test.id}.reply`);
      return { id: test.id, inputCount: input.length, replyCount: reply.length,
        exactInputCount: match(`${test.id}.user`, 'user', test.text).length,
        exactReplyCount: match(`${test.id}.reply`, 'assistant', test.expected).length,
        visibleMirrorCount: rows.filter(row => row.id.startsWith('official.') &&
          row.role === 'assistant' && row.text.includes(`同步编号：${test.id}`)).length,
        inputTimes: input.map(row => row.sentAt), replyTimes: reply.map(row => row.sentAt) };
    }),
    officialContext: {
      questionCount: rows.filter(row => row.id.startsWith('official.') && row.role === 'user' && row.text === official.question).length,
      questions: rows.filter(row => row.id.startsWith('official.') && row.role === 'user' && row.text === official.question)
        .map(row => ({ id: row.id, sentAt: row.sentAt })),
      replyID: `official.${official.preRepairExactReplyMatches.officialID}`,
      replyCount: match(`official.${official.preRepairExactReplyMatches.officialID}`, 'assistant', official.actualReply).length,
      replyTimes: match(`official.${official.preRepairExactReplyMatches.officialID}`, 'assistant', official.actualReply).map(row => row.sentAt),
    },
  };
}

async function main() {
  const sixPath = process.argv.length === 4 && process.argv[2] === '--read-authorized-six-page' ? process.argv[3] : null;
  if (!sixPath && (process.argv.length !== 3 || process.argv[2] !== '--read-authorized-latest-page')) throw Error('explicit_opt_in_required');
  const evidence = JSON.parse(await readFile(new URL('../artifacts/qa/dot-unread-followup-2026-10-13.json', import.meta.url), 'utf8'));
  const plan = dotStabilityPlan('d97fac82');
  const pairLines = (await readFile(new URL('../artifacts/qa/dot-unread-followup-2026-10-13/dot-reply-first-real-20261013.jsonl', import.meta.url), 'utf8'))
    .split('\n').filter(line => line.startsWith('{"stage":"submit-once"')).map(line => JSON.parse(line));
  let tests = evidence.ordinarySixRounds.rounds.map((row, index) => ({ id: row.id, text: plan[index].text, expected: plan[index].expected }))
    .concat(evidence.replyFirstPair.rounds.map(row => {
      const submitted = pairLines.find(item => item.id === row.id);
      if (!submitted) throw Error('missing_test_evidence');
      return { id: row.id, text: submitted.text, expected: submitted.expected };
    }));
  if (sixPath) {
    const raw = await readFile(sixPath, 'utf8');
    if (Buffer.byteLength(raw, 'utf8') > 256 * 1024) throw Error('invalid_six_result');
    const start = raw.lastIndexOf('{\n  "stage": "completed"');
    if (start < 0) throw Error('six_rounds_incomplete');
    const completed = JSON.parse(raw.slice(start));
    if (completed.stage !== 'completed' || completed.passed !== 6 || completed.rounds?.length !== 6) throw Error('six_rounds_incomplete');
    const currentPlan = dotStabilityPlan(completed.batch);
    tests = completed.rounds.map((row, index) => {
      if (row.label !== currentPlan[index].label || !/^[a-f0-9-]{36}$/.test(row.id ?? '')) throw Error('invalid_six_result');
      return { id: row.id, text: currentPlan[index].text, expected: currentPlan[index].expected };
    });
  }
  const config = await readFile(new URL('../Config/RemoteRelay.xcconfig', import.meta.url), 'utf8');
  const secret = config.match(/^CODEX_RELAY_SECRET\s*=\s*([A-Za-z0-9_-]{32,})\s*$/m)?.[1];
  if (!secret) throw Error('configuration_missing');
  const key = createHmac('sha256', secret).update('codex-control/dot-inbox/device/v1').digest('base64');
  // Exactly one GET, no cursor and no retry. Latest page is capped at 30 by the
  // deployed timeline implementation; unrelated rows stay in memory only.
  const response = await fetch('https://dot-inbox.example.com/v3/messages', {
    method: 'GET', redirect: 'error', signal: AbortSignal.timeout(15000),
    headers: { Authorization: `Bearer ${key}` },
  });
  if (!response.ok) throw Error(`cloud_http_${response.status}`);
  const result = summarizeAuthorizedPage(await response.json(), tests, evidence.officialContext, sixPath ? 6 : 8);
  console.log(JSON.stringify(result, null, 2));
  if (result.duplicatePageIDCount || result.tests.some(test => test.inputCount !== 1 || test.replyCount !== 1 ||
      test.exactInputCount !== 1 || test.exactReplyCount !== 1 || test.visibleMirrorCount !== 0) ||
      result.officialContext.questionCount !== 1 || result.officialContext.replyCount !== 1) process.exitCode = 2;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(error => {
    const code = /^[a-z0-9_]+$/.test(error?.message ?? '') ? error.message : 'verification_failed';
    console.error(JSON.stringify({ error: code }));
    process.exitCode = 1;
  });
}
