import assert from 'node:assert/strict';
import { test } from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import path from 'node:path';

const execute = promisify(execFile);
// These fixtures exercise macOS iCloud dataless-file recovery and BSD find.
// Do not pretend GNU find supplies the same placeholder semantics.
const macTest = process.platform === 'darwin' ? test : test.skip;
async function fixture(version = '1.0.0') {
  const root = await mkdtemp('/private/tmp/cloud-prep-fixture.');
  const fallback = await mkdtemp('/private/tmp/dot-cloud-source.');
  const dependencies = path.join(root, 'runtime/DotsGateway/node_modules');
  for (const name of ['scripts/lib', 'DotsGateway/src', 'DotsCallbackRelay/src', 'runtime/DotsGateway/node_modules/fixture']) {
    await mkdir(path.join(root, name), { recursive: true });
  }
  for (const name of ['scripts/prepare-cloud-source.mjs', 'scripts/lib/verified-local-read.mjs']) {
    await writeFile(path.join(root, name), await readFile(new URL('../../' + name, import.meta.url)));
  }
  await writeFile(path.join(root, 'DotsGateway/package.json'), JSON.stringify({ dependencies: { fixture: '1.0.0' } }));
  await writeFile(path.join(dependencies, 'fixture/package.json'), JSON.stringify({ version }));
  await writeFile(path.join(root, 'DotsGateway/src/index.ts'), 'current 中文🦦');
  await writeFile(path.join(root, 'DotsCallbackRelay/src/main.ts'), 'current callback');
  await mkdir(path.join(fallback, 'DotsGateway/src'), { recursive: true });
  await writeFile(path.join(fallback, 'DotsGateway/src/retired.ts'), 'must not return');
  return { root, fallback, dependencies };
}
async function run(f) {
  const result = await execute(process.execPath, [path.join(f.root, 'scripts/prepare-cloud-source.mjs'), f.fallback, f.dependencies], { timeout: 10_000 });
  return JSON.parse(result.stdout);
}
macTest('cloud preparation cannot resurrect retired fallback files and copies current bytes', async () => {
  const f = await fixture(); let result;
  try {
    result = await run(f);
    assert.equal(result.verifiedFiles, 3); assert.equal(result.inheritedPlaceholders, 0);
    assert.equal(await readFile(path.join(result.candidate, 'DotsGateway/src/index.ts'), 'utf8'), 'current 中文🦦');
    await assert.rejects(lstat(path.join(result.candidate, 'DotsGateway/src/retired.ts')), /ENOENT/);
    assert.equal((await lstat(path.join(result.candidate, 'DotsGateway/node_modules'))).isSymbolicLink(), true);
    assert.equal(await readFile(path.join(f.root, 'DotsGateway/src/index.ts'), 'utf8'), 'current 中文🦦');
  } finally {
    await rm(f.root, { recursive: true, force: true }); await rm(f.fallback, { recursive: true, force: true });
    if (result) await rm(result.candidate, { recursive: true, force: true });
  }
});
macTest('cloud preparation rejects a changed dependency version', async () => {
  const f = await fixture('2.0.0');
  try { await assert.rejects(run(f), error => /dependency_version_mismatch/.test(error.stderr)); }
  finally { await rm(f.root, { recursive: true, force: true }); await rm(f.fallback, { recursive: true, force: true }); }
});
macTest('cloud preparation rejects source symlinks rather than copying unknown targets', async () => {
  const f = await fixture();
  try {
    await symlink('../package.json', path.join(f.root, 'DotsGateway/src/alias.ts'));
    await assert.rejects(run(f), error => /source_symlink_requires_review/.test(error.stderr));
  } finally { await rm(f.root, { recursive: true, force: true }); await rm(f.fallback, { recursive: true, force: true }); }
});
