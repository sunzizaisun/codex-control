// Explicit local candidate reconstruction. Never modifies original placeholders.
import { execFileSync } from 'node:child_process';
import { lstat, mkdir, mkdtemp, readdir, symlink, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { verifiedLocalRead } from './lib/verified-local-read.mjs';
const [fallback, dependencies] = process.argv.slice(2);
if (process.argv.length !== 4 || !fallback?.startsWith('/private/tmp/dot-cloud-source.')
    || !dependencies?.startsWith('/private/tmp/') || !dependencies.endsWith('/DotsGateway/node_modules')) {
  throw Error('provide_explicit_local_source_and_dependencies');
}
const root = fileURLToPath(new URL('../', import.meta.url));
const inputs = ['DotsGateway', 'DotsCallbackRelay'];
const excluded = new Set(execFileSync('/usr/bin/find', [...inputs, '-type', 'd', '(',
  '-name', 'node_modules', '-o', '-name', '.wrangler', ')', '-prune', '-o',
  '-type', 'f', '-flags', '+dataless', '-print0'], { cwd: root }).toString().split('\0').filter(Boolean));
const destination = await mkdtemp('/private/tmp/dot-cloud-source.');
const verified = [], inherited = [];
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
async function walk(relative) {
  if (['node_modules', '.wrangler', '.DS_Store'].includes(path.basename(relative))
      || path.basename(relative).startsWith('._')) return;
  const source = path.join(root, relative), target = path.join(destination, relative);
  if (excluded.has(relative)) {
    let bytes;
    const inheritedSource = path.join(fallback, relative);
    try { bytes = await verifiedLocalRead(inheritedSource); }
    catch (error) {
      // Deno's separate network tests are not imported by Worker fixtures.
      // Keep the omission explicit; this candidate cannot claim Deno coverage.
      if (error.code === 'ENOENT' && relative.startsWith('DotsCallbackRelay/test/')) {
        inherited.push({ path: relative, missing: true, currentOriginalVerified: false });
        return;
      }
      throw error; // Missing runtime/Worker test source must stop reconstruction.
    }
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, bytes, { flag: 'wx', mode: 0o600 });
    if (!bytes.equals(await verifiedLocalRead(target)) || !bytes.equals(await verifiedLocalRead(inheritedSource))) {
      throw Error('inherited_source_changed_during_snapshot');
    }
    inherited.push({ path: relative, sha256: hash(bytes), currentOriginalVerified: false });
    return;
  }
  const stat = await lstat(source);
  if (stat.isSymbolicLink()) throw Error('source_symlink_requires_review');
  if (stat.isDirectory()) {
    await mkdir(target, { recursive: true });
    for (const entry of await readdir(source)) await walk(path.join(relative, entry));
  } else if (stat.isFile()) {
    const bytes = await verifiedLocalRead(source);
    await writeFile(target, bytes, { flag: 'wx', mode: 0o600 });
    if (!bytes.equals(await verifiedLocalRead(target)) || !bytes.equals(await verifiedLocalRead(source))) throw Error('source_changed_during_snapshot');
    verified.push({ path: relative, sha256: hash(bytes) });
  }
}
for (const input of inputs) await walk(input);
const packageJSON = JSON.parse(await verifiedLocalRead(path.join(destination, 'DotsGateway/package.json')));
for (const [name, expected] of Object.entries({ ...packageJSON.dependencies, ...packageJSON.devDependencies })) {
  const installed = JSON.parse(await verifiedLocalRead(path.join(dependencies, name, 'package.json')));
  if (installed.version !== expected) throw Error('dependency_version_mismatch');
}
await symlink(dependencies, path.join(destination, 'DotsGateway/node_modules'));
await writeFile(path.join(destination, 'candidate-manifest.json'), JSON.stringify({
  sourceFallback: fallback, localDependencies: dependencies, verified, inherited,
  latestCompleteSourceVerified: inherited.length === 0, remoteBindingsUsed: false,
}, null, 2), { mode: 0o600 });
console.log(JSON.stringify({ candidate: destination, verifiedFiles: verified.length,
  inheritedPlaceholders: inherited.length, latestCompleteSourceVerified: inherited.length === 0 }));
