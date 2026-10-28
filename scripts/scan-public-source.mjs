import { readdir, lstat, readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
export async function scanPublicSource(root = fileURLToPath(new URL('../', import.meta.url))) {
  const failures = [];
  let scanned = 0;
  const skipped = new Set(['.git', 'node_modules', '.build', '.swiftpm', '.wrangler', 'DerivedData']);
  const forbiddenDirectory = new Set(['backups', 'artifacts', 'outputs', 'experiments', 'xcuserdata']);
  const sensitiveName = /(?:^\.env(?!\.example$)|^\.dev\.vars(?!\.example$)|\.(?:p12|p8|pem|key|mobileprovision|provisionprofile|ipa|dmg|xcuserstate)$|^RemoteRelay\.xcconfig$)/;
  const rules = [
    ['private-key-pem', /-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----/],
    ['github-token', /\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{35,})\b/],
    ['slack-token', /\bxox[baprs]-[A-Za-z0-9-]{20,}\b/],
    ['provider-api-key', /\bsk-(?:proj-)?[A-Za-z0-9_-]{30,}\b/],
    ['aws-access-key', /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/],
    ['credential-in-url', /https?:\/\/[^\s/"'<>]+:[^\s/"'<>]+@/],
  ];
  const reviewedURLFixtures = new Set(['DotsCallbackRelay/test/client.test.ts', 'DotsCallbackRelay/test/relay.test.ts',
    'DotsGateway/test/events/delivery.test.ts', 'DotsGateway/test/events/events.test.ts', 'RemoteRelay/tests/device-auth.test.mjs',
    'Tests/CodexWatchCoreTests/DotsTests.swift', 'Tests/CodexWatchCoreTests/RelayDeviceProofTests.swift',
    'Tests/CodexWatchCoreTests/RelayOwnerCredentialTests.swift']);
  async function walk(relative = '') {
    if (relative.split(path.sep).some(part => forbiddenDirectory.has(part))) { failures.push({path:relative,rule:'private-or-build-directory'}); return; }
    const absolute = path.join(root, relative);
    const stat = await lstat(absolute);
    const name = path.basename(relative);
    if (stat.isSymbolicLink()) { failures.push({path:relative,rule:'symlink'}); return; }
    if (stat.isDirectory()) {
      if (skipped.has(name)) return;
      if (forbiddenDirectory.has(name) || /\.(app|xcresult)$/.test(name)) { failures.push({path:relative,rule:'private-or-build-directory'}); return; }
      for (const entry of (await readdir(absolute)).sort()) await walk(path.join(relative,entry));
    } else if (stat.isFile()) {
      // Local configuration is intentionally generated but must never be staged.
      // Git mode additionally audits the tracked publication set instead.
      if (sensitiveName.test(name)) { failures.push({path:relative,rule:'sensitive-file'}); return; }
      if (stat.size > 8*1024*1024) { failures.push({path:relative,rule:'oversized-file'}); return; }
      const bytes = await readFile(absolute); scanned++;
      const text = bytes.toString('utf8');
      if (!Buffer.from(text).equals(bytes)) {
        if (!relative.endsWith('.png')) failures.push({path:relative,rule:'unreviewed-binary'});
        return;
      }
      for (const [rule, pattern] of rules) {
        const inspected = rule === 'credential-in-url' && reviewedURLFixtures.has(relative)
          ? text.replace(/https:\/\/(?:user:pass(?:word)?|u:p)@(?:[a-z0-9.-]+\.example|(?:owner-qa|mcp-callback)\.invalid|example\.com|callbacks\.wearable\.deno\.net)(?=[/"'\s])/g, 'https://fixture.invalid') : text;
        if (pattern.test(inspected)) failures.push({path:relative,rule});
      }
    }
  }
  let repository = false;
  try { await lstat(path.join(root,'.git')); repository=true; } catch(error) { if(error.code!=='ENOENT')throw error; }
  if(repository){
    const {stdout}=await promisify(execFile)('git',['-C',root,'ls-files','--cached','-z'],{maxBuffer:4*1024*1024});
    const files=stdout.split('\0').filter(Boolean);
    if(!files.length)throw Error('empty_tracked_publication');
    for(const file of files)await walk(file);
  }else await walk();
  return {scanned, failures};
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = await scanPublicSource();
  console.log(JSON.stringify(result,null,2));
  if(result.failures.length)process.exitCode=1;
}
