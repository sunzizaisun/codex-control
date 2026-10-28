import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { chmod, lstat, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { verifiedLocalRead } from './verified-local-read.mjs';

const inputs = ['Apps', 'Sources', 'Tests', 'Resources', 'Config', 'CodexWatch.xcodeproj', 'Package.swift'];
const extraInputs = ['scripts/dot-native-tests.yml', 'scripts/native-interface-tests.yml', 'scripts/controller-fault-tests.yml'];
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const defaultIO = { lstat, readFile, mkdir, writeFile, chmod };

export async function copyVerifiedSnapshotFile(source, destination, io = defaultIO) {
  const bytes = await verifiedLocalRead(source, io);
  const attributes = await io.lstat(source);
  await io.mkdir(path.dirname(destination), { recursive: true });
  await io.writeFile(destination, bytes, { flag: 'wx', mode: attributes.mode & 0o777 });
  const [copied, current] = await Promise.all([
    verifiedLocalRead(destination, io), verifiedLocalRead(source, io),
  ]);
  if (hash(copied) !== hash(bytes) || hash(current) !== hash(bytes)) throw Error('snapshot_copy_or_source_changed');
  return { bytes: bytes.byteLength, sha256: hash(bytes) };
}

export async function prepareNativeSnapshot(projectRoot, {
  fallback, findPlaceholders = () => execFileSync('/usr/bin/find',
    [...inputs, ...extraInputs, '-type', 'f', '-flags', '+dataless', '-print0'], { cwd: projectRoot, maxBuffer: 4 * 1024 * 1024 }),
  temporaryRoot = '/private/tmp',
} = {}) {
  const placeholders = new Set(findPlaceholders().toString('utf8').split('\0').filter(Boolean));
  if (placeholders.size && !fallback) throw Error('source_placeholders_require_explicit_verified_fallback');
  if (fallback) {
    const stat = await lstat(fallback);
    if (!fallback.startsWith('/private/tmp/codex-simulator-source.') || path.resolve(fallback) !== fallback
        || !stat.isDirectory() || stat.isSymbolicLink()) throw Error('fallback_must_be_explicit_local_simulator_snapshot');
  }
  const destination = await mkdtemp(path.join(temporaryRoot, 'codex-simulator-source.'));
  await chmod(destination, 0o700);
  const files = [];
  async function copy(relative, destinationRelative = relative) {
    const current = path.join(projectRoot, relative), stat = await lstat(current);
    if (stat.isSymbolicLink()) throw Error('source_symlink_requires_review');
    if (stat.isDirectory()) {
      await mkdir(path.join(destination, destinationRelative), { recursive: true });
      for (const name of (await readdir(current)).sort()) {
        if (name === '.DS_Store' || name.startsWith('._')) continue;
        await copy(path.join(relative, name), path.join(destinationRelative, name));
      }
    } else if (stat.isFile()) {
      const inherited = placeholders.has(relative);
      // Enumerate the CURRENT tree only. Deleted source files cannot return
      // from an older fallback. Never modify or hydrate the original files.
      const source = inherited ? path.join(fallback, destinationRelative) : current;
      files.push({ path: destinationRelative, sourcePath: relative, inherited,
        ...(await copyVerifiedSnapshotFile(source, path.join(destination, destinationRelative))) });
    } else { throw Error('unsupported_source_file_type'); }
  }
  for (const relative of inputs) await copy(relative);
  for (const relative of extraInputs) await copy(relative, path.basename(relative));
  const manifest = { createdAt: new Date().toISOString(), projectRoot, fallback: fallback ?? null,
    files, currentFiles: files.filter(file => !file.inherited).length,
    inheritedFiles: files.filter(file => file.inherited).length,
    physicalDeviceInstall: false, originalFilesModified: false,
    limits: 'Verified bytes at preparation time only. Inherited files are not proof of current placeholder bytes.' };
  await writeFile(path.join(destination, 'native-source-manifest.json'), JSON.stringify(manifest, null, 2) + '\n',
    { flag: 'wx', mode: 0o600 });
  return { destination, currentFiles: manifest.currentFiles, inheritedFiles: manifest.inheritedFiles };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const args = process.argv.slice(2);
  if (args.length && (args.length !== 2 || args[0] !== '--fallback')) throw Error('use_optional_explicit_fallback');
  const projectRoot = fileURLToPath(new URL('../../', import.meta.url));
  const result = await prepareNativeSnapshot(projectRoot, { fallback: args[1] });
  console.error(JSON.stringify({ currentFiles: result.currentFiles, inheritedFiles: result.inheritedFiles }));
  // Preserve verify-local.sh's existing last-colon path contract.
  console.log(`${result.inheritedFiles ? 'Reconstructed' : 'Verified'} simulator source snapshot: ${result.destination}`);
}
