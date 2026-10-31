// Source-build convenience only. No installation, no account access, no upload.
import { execFileSync } from 'node:child_process';
import { cp, lstat, mkdir, mkdtemp, readFile, readdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { developmentEnvironment, prepareXcode, projectRoot } from './prepare-xcode.mjs';

const inputs = ['Apps', 'Sources', 'Tests', 'Resources', 'Package.swift', 'project.yml',
  'Config/RemoteRelay.example.xcconfig', 'scripts/bootstrap.mjs', 'scripts/generate-icons.mjs'];

// Enumerate only the required public source, never the user's local Config,
// Keychain, existing build products or signing profiles.
export async function copyBuildSource(root, destination) {
  async function copy(relative) {
    const source = path.join(root, relative), target = path.join(destination, relative);
    const stat = await lstat(source);
    if (stat.isSymbolicLink()) throw Error('build_source_symlink');
    if (stat.isDirectory()) {
      await mkdir(target, { recursive: true });
      for (const name of await readdir(source)) {
        if (name === '.DS_Store' || name.startsWith('._')) continue;
        await copy(path.join(relative, name));
      }
    } else if (stat.isFile()) {
      await mkdir(path.dirname(target), { recursive: true });
      await cp(source, target, { errorOnExist: true, force: false });
    } else throw Error('unsupported_build_source');
  }
  for (const input of inputs) await copy(input);
}

export async function verifyBlankConfiguration(app, run = execFileSync) {
  for (const key of ['CodexRelayURL', 'CodexRelayRoom', 'CodexRelaySecret']) {
    const value = run('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, path.join(app, 'Contents/Info.plist')], { encoding: 'utf8' }).trim();
    if (value !== '') throw Error('package_contains_nonempty_configuration');
  }
}

export function verifyArchitectures(app, { env = process.env, run = execFileSync } = {}) {
  const archs = run('/usr/bin/lipo', ['-archs', path.join(app, 'Contents/MacOS/Agent Bridge')], { env, encoding: 'utf8' }).trim().split(/\s+/).sort();
  if (JSON.stringify(archs) !== JSON.stringify(['arm64', 'x86_64'])) throw Error('package_is_not_universal');
}

export function validateArchiveEntries(list) {
  const entries = list.trim().split('\n');
  if (!entries.length || entries.some(entry => entry.startsWith('/') || entry.split('/').some(part =>
    part === '..' || part === '__MACOSX' || part === '.DS_Store' || part.startsWith('._')
    || part === 'RemoteRelay.xcconfig' || /\.(?:p12|p8|pem|key|mobileprovision|provisionprofile)$/.test(part)))) {
    throw Error('unexpected_package_entry');
  }
}

export async function buildMac({ root = projectRoot, reveal = true,
  env = developmentEnvironment(), run = execFileSync } = {}) {
  const scratch = await mkdtemp(path.join(tmpdir(), 'codex-mac-build-'));
  console.log(`Build workspace: ${scratch}`);
  await copyBuildSource(root, scratch);
  prepareXcode({ root: scratch, env, open: false, run });
  run('/usr/bin/xcodebuild', ['-project', 'CodexWatch.xcodeproj', '-scheme', 'AgentBridgeMac',
    '-configuration', 'Release', '-destination', 'generic/platform=macOS',
    '-derivedDataPath', path.join(scratch, 'DerivedData'),
    'ARCHS=arm64 x86_64', 'ONLY_ACTIVE_ARCH=NO', 'CODE_SIGN_STYLE=Manual', 'CODE_SIGN_IDENTITY=-', 'build'],
  { cwd: scratch, env, stdio: 'inherit' });
  const app = path.join(scratch, 'DerivedData/Build/Products/Release/Agent Bridge.app');
  return { ...(await packageMac({ app, root, reveal, env, run })), scratch };
}

export async function packageMac({ app, root = projectRoot, reveal = true,
  env = process.env, run = execFileSync }) {
  await verifyBlankConfiguration(app, run);
  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', app], { env, stdio: 'inherit' });
  verifyArchitectures(app, { env, run });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const output = path.join(root, 'dist', `mac-${stamp}`);
  await mkdir(path.dirname(output), { recursive: true });
  await mkdir(output); // Refuse to overwrite an existing package.
  const bundle = path.join(output, 'Codex-Control-Mac');
  await mkdir(bundle);
  run('/usr/bin/ditto', ['--norsrc', '--noextattr', '--noacl', app, path.join(bundle, 'Agent Bridge.app')], { env, stdio: 'inherit' });
  for (const name of ['LICENSE', 'THIRD_PARTY_NOTICES.md']) await cp(path.join(root, name), path.join(bundle, name));
  await writeFile(path.join(bundle, 'READ-ME.txt'), [
    'Codex Control — Mac source build (Apple Silicon + Intel)',
    '',
    'Drag Agent Bridge.app into Applications if you choose to install it.',
    'This build uses an ad-hoc signature. It is NOT Developer ID signed or Apple notarized.',
    'It does not contain a public backend or account credentials. Configure your own service.',
    'macOS may block an app received from the Internet. Do not disable Gatekeeper.',
    'iPhone and Apple Watch apps are not included; use your own Xcode signing or TestFlight.',
    '',
    '可将 Agent Bridge.app 拖入“应用程序”。本包仅为本地临时签名，未经过苹果公证。',
    '不含私人密钥或公共后端；首次使用仍需配置和配对。请勿关闭系统安全保护。',
    '',
  ].join('\n'));
  const archive = path.join(output, 'Codex-Control-Mac-universal.zip');
  // Distribute file contents, not machine-specific Finder/AppleDouble metadata.
  run('/usr/bin/ditto', ['-c', '-k', '--norsrc', '--noextattr', '--noacl', '--keepParent', bundle, archive], { env, stdio: 'inherit' });
  run('/usr/bin/unzip', ['-tqq', archive], { env, stdio: 'inherit' });
  validateArchiveEntries(run('/usr/bin/unzip', ['-Z', '-1', archive], { env, encoding: 'utf8' }));
  const checksum = createHash('sha256').update(await readFile(archive)).digest('hex');
  await writeFile(path.join(output, 'SHA256SUMS.txt'), `${checksum}  ${path.basename(archive)}\n`);
  console.log(`Package ready: ${archive}\nNo app installed or launched. Not notarized.`);
  if (reveal) run('/usr/bin/open', [output], { env, stdio: 'inherit' });
  return { archive, checksum };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.some(arg => arg !== '--no-open') || args.length > 1) throw Error('Usage: node scripts/build-mac.mjs [--no-open]');
    await buildMac({ reveal: !args.includes('--no-open') });
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
