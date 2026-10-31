import assert from 'node:assert/strict';
import { test } from 'node:test';
import { chmod, lstat, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { copyVerifiedSnapshotFile, prepareNativeSnapshot } from '../lib/prepare-native-snapshot.mjs';

async function fixture() {
  const root = await mkdtemp(path.join(tmpdir(), 'native-prep-fixture.'));
  for (const name of ['Apps', 'Sources', 'Tests', 'Resources', 'Config', 'CodexWatch.xcodeproj', 'scripts']) await mkdir(path.join(root, name));
  await writeFile(path.join(root, 'Package.swift'), 'package fixture');
  await writeFile(path.join(root, 'Sources/Fixture.swift'), '中文🦦');
  await writeFile(path.join(root, 'scripts/dot-native-tests.yml'), 'test fixture');
  await writeFile(path.join(root, 'scripts/native-interface-tests.yml'), 'interface test fixture');
  await writeFile(path.join(root, 'scripts/controller-fault-tests.yml'), 'controller test fixture');
  return root;
}
test('native snapshot rejects silent empty source reads before writing', async () => {
  let writes = 0;
  const stat = { isFile: () => true, size: 9, ino: 1, dev: 2, mtimeMs: 3 };
  await assert.rejects(copyVerifiedSnapshotFile('source', 'destination', {
    lstat: async () => stat, readFile: async () => Buffer.alloc(0), writeFile: async () => { writes++; },
  }), /incomplete_or_changed_source_read/);
  assert.equal(writes, 0);
});
test('native snapshot preserves exact bytes, executable mode and provenance', async () => {
  const root = await fixture(); let snapshot;
  try {
    await chmod(path.join(root, 'Sources/Fixture.swift'), 0o755);
    snapshot = await prepareNativeSnapshot(root, { findPlaceholders: () => Buffer.alloc(0), temporaryRoot: tmpdir() });
    assert.equal(snapshot.currentFiles, 5); assert.equal(snapshot.inheritedFiles, 0);
    assert.equal(await readFile(path.join(snapshot.destination, 'Sources/Fixture.swift'), 'utf8'), '中文🦦');
    assert.equal((await lstat(path.join(snapshot.destination, 'Sources/Fixture.swift'))).mode & 0o777, 0o755);
    assert.equal(await readFile(path.join(snapshot.destination, 'dot-native-tests.yml'), 'utf8'), 'test fixture');
    assert.equal(await readFile(path.join(snapshot.destination, 'native-interface-tests.yml'), 'utf8'), 'interface test fixture');
    assert.equal(await readFile(path.join(snapshot.destination, 'controller-fault-tests.yml'), 'utf8'), 'controller test fixture');
    const manifest = JSON.parse(await readFile(path.join(snapshot.destination, 'native-source-manifest.json'), 'utf8'));
    assert.equal(manifest.files.length, 5); assert.equal(manifest.originalFilesModified, false);
  } finally { await rm(root, { recursive: true, force: true }); if (snapshot) await rm(snapshot.destination, { recursive: true, force: true }); }
});
test('explicit fallback marks inherited bytes but cannot resurrect deleted files', { skip: process.platform !== 'darwin' }, async () => {
  const root = await fixture(), fallback = await mkdtemp('/private/tmp/codex-simulator-source.'); let snapshot;
  try {
    await mkdir(path.join(fallback, 'Sources'));
    await writeFile(path.join(fallback, 'Sources/Fixture.swift'), 'older verified candidate');
    await writeFile(path.join(fallback, 'Sources/Deleted.swift'), 'must not return');
    const findPlaceholders = () => Buffer.from('Sources/Fixture.swift\0');
    await assert.rejects(prepareNativeSnapshot(root, { findPlaceholders }), /explicit_verified_fallback/);
    snapshot = await prepareNativeSnapshot(root, { fallback, findPlaceholders });
    assert.equal(snapshot.inheritedFiles, 1);
    assert.equal(await readFile(path.join(snapshot.destination, 'Sources/Fixture.swift'), 'utf8'), 'older verified candidate');
    await assert.rejects(lstat(path.join(snapshot.destination, 'Sources/Deleted.swift')), /ENOENT/);
    assert.equal(await readFile(path.join(root, 'Sources/Fixture.swift'), 'utf8'), '中文🦦');
  } finally {
    await rm(root, { recursive: true, force: true }); await rm(fallback, { recursive: true, force: true });
    if (snapshot) await rm(snapshot.destination, { recursive: true, force: true });
  }
});
test('native snapshot rejects symlinks instead of copying unknown targets', async () => {
  const root = await fixture();
  try {
    await symlink('../Package.swift', path.join(root, 'Sources/Link.swift'));
    await assert.rejects(prepareNativeSnapshot(root, { findPlaceholders: () => Buffer.alloc(0), temporaryRoot: tmpdir() }), /symlink_requires_review/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
