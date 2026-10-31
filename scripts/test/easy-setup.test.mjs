import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, lstat, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { developmentEnvironment, prepareXcode } from '../prepare-xcode.mjs';
import { copyBuildSource, verifyBlankConfiguration, verifyArchitectures } from '../build-mac.mjs';

test('setup uses full Xcode per process without changing the system selection', () => {
  const calls = [];
  const env = developmentEnvironment({ platform: 'darwin', env: { PATH: '/usr/bin' },
    exists: file => file.startsWith('/Applications/Xcode.app/'),
    run: (command, args) => {
      calls.push([command, args]);
      return command.endsWith('xcode-select') ? '/Library/Developer/CommandLineTools\n'
        : command === 'xcodegen' ? 'Version: 2.45.4\n' : 'Xcode 27.2\n';
    } });
  assert.equal(env.DEVELOPER_DIR, '/Applications/Xcode.app/Contents/Developer');
  assert.deepEqual(calls[0][1], ['-p']);
  assert(!JSON.stringify(calls).includes('--switch'));
});

test('setup fails clearly for missing or old XcodeGen and non-Mac hosts', () => {
  assert.throws(() => developmentEnvironment({ platform: 'linux' }), /macOS is required/);
  for (const version of [null, 'Version: 2.45.3', 'unexpected']) {
    assert.throws(() => developmentEnvironment({ platform: 'darwin', env: {}, exists: () => true,
      run: command => {
        if (command.endsWith('xcode-select')) return '/Applications/Xcode.app/Contents/Developer';
        if (command === 'xcodegen') { if (version === null) throw Error('missing'); return version; }
        return 'Xcode 27';
      } }), /XcodeGen/);
  }
});

test('headless setup prepares in order but never opens, installs or starts an app', () => {
  const calls = [];
  prepareXcode({ root: '/tmp/project with spaces', env: {}, open: false,
    run: (command, args) => { calls.push([command, args]); } });
  assert.equal(calls.length, 3);
  assert(calls[0][1][0].endsWith('/scripts/bootstrap.mjs'));
  assert(calls[1][1][0].endsWith('/scripts/generate-icons.mjs'));
  assert.deepEqual(calls[2], ['xcodegen', ['generate']]);
});

test('setup stops on a failed preparation instead of opening a stale project', () => {
  const calls = [];
  assert.throws(() => prepareXcode({ env: {}, run: command => {
    calls.push(command); throw Error('preparation failed');
  } }), /preparation failed/);
  assert.equal(calls.length, 1);
});

test('bootstrap preserves an existing private configuration exactly', async () => {
  const root = await mkdtemp(path.join(tmpdir(), 'codex-setup-'));
  try {
    await mkdir(path.join(root, 'scripts')); await mkdir(path.join(root, 'Config'));
    await writeFile(path.join(root, 'scripts/bootstrap.mjs'), await readFile(new URL('../bootstrap.mjs', import.meta.url)));
    await writeFile(path.join(root, 'Config/RemoteRelay.example.xcconfig'), 'EMPTY=\n');
    const run = () => execFileSync(process.execPath, [path.join(root, 'scripts/bootstrap.mjs')]);
    run();
    assert.equal(await readFile(path.join(root, 'Config/RemoteRelay.xcconfig'), 'utf8'), 'EMPTY=\n');
    await writeFile(path.join(root, 'Config/RemoteRelay.xcconfig'), 'PRIVATE_CONFIGURATION_KEEP');
    run();
    assert.equal(await readFile(path.join(root, 'Config/RemoteRelay.xcconfig'), 'utf8'), 'PRIVATE_CONFIGURATION_KEEP');
  } finally { await rm(root, { recursive: true }); }
});

async function fixture() {
  const root = await mkdtemp(path.join(tmpdir(), 'codex-package-test-'));
  const source = path.join(root, 'source'), destination = path.join(root, 'isolated');
  for (const name of ['Apps', 'Sources', 'Tests', 'Resources', 'Config', 'scripts', 'dist']) await mkdir(path.join(source, name), { recursive: true });
  for (const name of ['Package.swift', 'project.yml', 'Config/RemoteRelay.example.xcconfig', 'scripts/bootstrap.mjs', 'scripts/generate-icons.mjs']) await writeFile(path.join(source, name), 'public fixture');
  await writeFile(path.join(source, 'Config/RemoteRelay.xcconfig'), 'DO_NOT_PACKAGE_PRIVATE_CONFIG');
  await writeFile(path.join(source, 'dist/old-app.txt'), 'DO_NOT_PACKAGE_OLD_BUILD');
  return { root, source, destination };
}

test('Mac package staging excludes private config and old build products', async () => {
  const f = await fixture();
  try {
    await copyBuildSource(f.source, f.destination);
    assert.equal(await readFile(path.join(f.destination, 'Config/RemoteRelay.example.xcconfig'), 'utf8'), 'public fixture');
    await assert.rejects(lstat(path.join(f.destination, 'Config/RemoteRelay.xcconfig')), /ENOENT/);
    await assert.rejects(lstat(path.join(f.destination, 'dist')), /ENOENT/);
    assert.equal(await readFile(path.join(f.source, 'Config/RemoteRelay.xcconfig'), 'utf8'), 'DO_NOT_PACKAGE_PRIVATE_CONFIG');
  } finally { await rm(f.root, { recursive: true }); }
});

test('Mac package staging rejects source symlinks', async () => {
  const f = await fixture();
  try {
    await symlink('../Config/RemoteRelay.xcconfig', path.join(f.source, 'Apps/alias'));
    await assert.rejects(copyBuildSource(f.source, f.destination), /build_source_symlink/);
  } finally { await rm(f.root, { recursive: true }); }
});

test('packaging refuses a build with a populated service or credential field', async () => {
  const keys = [];
  await verifyBlankConfiguration('/tmp/mock.app', (_, args) => { keys.push(args[1]); return '\n'; });
  assert.equal(keys.length, 3);
  await assert.rejects(verifyBlankConfiguration('/tmp/mock.app', () => 'PRIVATE_VALUE'), /package_contains_nonempty_configuration/);
});

test('architecture verification parses lipo output and refuses single-architecture packages', () => {
  const app = '/tmp/app with spaces.app';
  verifyArchitectures(app, { run: (command, args) => {
    assert.equal(command, '/usr/bin/lipo');
    assert.deepEqual(args, ['-archs', `${app}/Contents/MacOS/Agent Bridge`]);
    return 'x86_64 arm64\n';
  } });
  for (const output of ['arm64', 'x86_64', '', 'arm64 x86_64 extra']) {
    assert.throws(() => verifyArchitectures(app, { run: () => output }), /package_is_not_universal/);
  }
});
