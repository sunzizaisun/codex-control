import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const projectRoot = fileURLToPath(new URL('../', import.meta.url));

export function developmentEnvironment({ env = process.env, exists = existsSync,
  run = execFileSync, platform = process.platform } = {}) {
  if (platform !== 'darwin') throw Error('需要 Mac / macOS is required.');
  if (Number(process.versions.node.split('.')[0]) < 24) throw Error('需要 Node.js 24+ / Node.js 24+ is required.');
  let selected;
  try { selected = run('/usr/bin/xcode-select', ['-p'], { encoding: 'utf8' }).trim(); } catch { /* use installed full Xcode */ }
  const developer = [env.DEVELOPER_DIR, selected, '/Applications/Xcode.app/Contents/Developer']
    .find(candidate => candidate && exists(path.join(candidate, 'usr/bin/xcodebuild'))
      && exists(path.join(candidate, 'Platforms/MacOSX.platform')));
  if (!developer) throw Error('请先安装完整 Xcode 并打开一次完成许可 / Install full Xcode and open it once to finish setup.');
  const result = { ...env, DEVELOPER_DIR: developer };
  run('/usr/bin/xcodebuild', ['-version'], { env: result, stdio: 'pipe' });
  let version;
  try { version = run('xcodegen', ['--version'], { env: result, encoding: 'utf8' }); }
  catch { throw Error('缺少 XcodeGen；请先安装 / XcodeGen is required: brew install xcodegen'); }
  const match = version.match(/(\d+)\.(\d+)\.(\d+)/);
  if (!match || match.slice(1).map(Number).reduce((v, n) => v * 1000 + n, 0) < 2045004) {
    throw Error('需要 XcodeGen 2.45.4+ / XcodeGen 2.45.4+ is required.');
  }
  return result;
}

export function prepareXcode({ root = projectRoot, env = developmentEnvironment(),
  open = true, run = execFileSync } = {}) {
  const options = { cwd: root, env, stdio: 'inherit' };
  run(process.execPath, [path.join(root, 'scripts/bootstrap.mjs')], options);
  run(process.execPath, [path.join(root, 'scripts/generate-icons.mjs')], options);
  run('xcodegen', ['generate'], options);
  if (open) run('/usr/bin/open', [path.join(root, 'CodexWatch.xcodeproj')], options);
  console.log('工程已准备好，不会安装或启动设备应用 / Project ready. No apps were installed or launched.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const args = process.argv.slice(2);
    if (args.some(arg => arg !== '--no-open') || args.length > 1) throw Error('Usage: node scripts/prepare-xcode.mjs [--no-open]');
    prepareXcode({ open: !args.includes('--no-open') });
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
