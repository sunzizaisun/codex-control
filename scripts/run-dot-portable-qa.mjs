import { randomUUID } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { dotCloudRequest, portableDotPlan, runPortableDotAcceptance } from './lib/dot-portable-acceptance.mjs';

const args = process.argv.slice(2);
if (args.length === 0 || (args.length === 1 && args[0] === '--plan')) {
  console.log(JSON.stringify({ newMessageLimit: 4, historyControlLimit: 1, autoPostRetries: 0,
    macBridgeUsed: false, plan: portableDotPlan(randomUUID().slice(0, 8)) }, null, 2));
} else if (args.length === 1 && args[0] === '--run-four') {
  const key = process.env.DOT_QA_DEVICE_KEY;
  if (!key || !process.env.DOT_QA_ORIGIN) throw Error('explicit_qa_origin_and_device_key_required');
  try {
    await runPortableDotAcceptance({ request: dotCloudRequest(key), sleep,
      emit: value => console.log(JSON.stringify(value)) });
  } catch (error) {
    // Only expose our bounded machine code. In particular, fetch's exception
    // cause and request headers must never enter an artifact.
    const firstLine = (error.message ?? '').split('\n')[0];
    const safe = /^(?:qa_http_[0-9]{3}:[a-z0-9_]+|[a-z_]+(?::[a-f0-9-]{36})?)$/.test(firstLine) ? firstLine : 'qa_stopped';
    console.log(JSON.stringify({ stage: 'stopped', reason: safe, furtherSends: 0 }));
    process.exitCode = 1;
  }
} else { throw Error('Use --plan or --run-four'); }
