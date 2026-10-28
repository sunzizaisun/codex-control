// Offline workerd runner. No install, deploy, server listener, production
// credentials or device control. All executable/dependency paths are explicit.
import { createHash } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmod, lstat, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { verifiedLocalRead } from './lib/verified-local-read.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const args = process.argv.slice(2), options = {};
const usage = 'explicit --workerd <binary> --esbuild <lib/main.js> --jose <package directory> required';
for (let index = 0; index < args.length; index += 2) {
  if (!['--workerd', '--esbuild', '--jose'].includes(args[index]) || options[args[index]] || !args[index + 1]) throw Error(usage);
  options[args[index]] = args[index + 1];
}
if (Object.keys(options).length !== 3) throw Error(usage);
for (const [name, value] of Object.entries(options)) {
  if (!path.isAbsolute(value) || path.resolve(value) !== value) throw Error('absolute_canonical_dependency_paths_required');
  const stat = await lstat(value);
  if (stat.isSymbolicLink() || (name === '--jose' ? !stat.isDirectory() : !stat.isFile())) throw Error('review_dependency_target');
}
const dependency = JSON.parse(await verifiedLocalRead(path.join(options['--jose'], 'package.json')));
const locked = JSON.parse(await verifiedLocalRead(path.join(root, 'RemoteRelay/package-lock.json')));
if (dependency.name !== 'jose' || dependency.version !== locked.packages?.['node_modules/jose']?.version
    || path.basename(options['--jose']) !== 'jose') throw Error('explicit_locked_jose_package_required');
const fixture = JSON.parse(await verifiedLocalRead(path.join(root, 'RemoteRelay/tests/fixtures/swift-signed-envelope.json')));
if (fixture.synthetic !== true || fixture.identity?.deviceID !== 'qa-phone'
    || fixture.identity?.jwk?.x !== '11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo'
    || fixture.originalSHA256 !== 'a916afaad4e696813820b766126644e0eba63ab7e93704939a975c497b5ab196') {
  throw Error('only_known_public_synthetic_fixture_allowed');
}
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const version = execFileSync(options['--workerd'], ['--version'], { encoding: 'utf8', timeout: 5000 }).trim();
if (!/^workerd \d{4}-\d\d-\d\d$/.test(version)) throw Error('unknown_workerd_version');
const directory = await mkdtemp('/private/tmp/relay-workerd-qa.');
await chmod(directory, 0o700); await mkdir(path.join(directory, 'db'), { mode: 0o700 });
const files = ['RemoteRelay/src/device-auth.mjs', 'RemoteRelay/src/signed-envelope.mjs',
  'RemoteRelay/tests/runtime/device-auth-workerd.mjs', 'RemoteRelay/tests/runtime/device-auth-workerd.capnp',
  'RemoteRelay/tests/fixtures/swift-signed-envelope.json', 'RemoteRelay/src/device-enrollment.mjs',
  'RemoteRelay/tests/fixtures/swift-enrollment.json', 'RemoteRelay/tests/fixtures/runtime-device-roots.json',
  'RemoteRelay/src/index.js', 'RemoteRelay/src/packet.mjs', 'RemoteRelay/src/auth-v2.mjs',
  'RemoteRelay/src/device-routing.mjs', 'RemoteRelay/src/device-packets.mjs', 'RemoteRelay/src/device-relay.mjs'];
files.push('RemoteRelay/src/device-json.mjs', 'RemoteRelay/src/device-key-delivery.mjs',
  'RemoteRelay/tests/fixtures/swift-key-delivery.json');
const manifest = { createdAt: new Date().toISOString(), directory, runtimeVersion: version,
  dependency: { name: 'jose', version: dependency.version }, files: [], phases: [], status: 'preparing',
  networkOutboundAllowed: false, listeningSockets: 0, installedDependencies: false,
  liveCloudActions: 0, physicalDeviceActions: 0, actualWorkerd: true, productionCloudAcceptance: false };
const expectedTests = ['cryptoInterop', 'enrollmentCryptoInterop', 'persistentReplayFirst', 'concurrentReplay', 'durableRevocation',
  'rollbackAndWriteFailure', 'mobileRoleCannotEscalate', 'persistentReplayAfterRestart',
  'enrollmentConcurrentAndReceipt', 'enrollmentRollback', 'enrollmentRevocation', 'enrollmentAfterProcessRestart',
  'actualHTTPDeliveryAndIdempotentACK', 'actualHTTPPagination', 'actualHTTPPersistedReceiptFirst',
  'actualHTTPInvitationAndLegacyBoundary', 'actualHTTPUnmigratedV2Compatibility', 'actualHTTPWebSocketRevocation',
  'actualHTTPIdleExpiryClosesSocket', 'actualHTTPPersistedReceiptAfterRestart',
  'actualHTTPNativeKeyDelivery', 'actualHTTPNativeKeyDeliveryAfterRestart',
  'actualKeyRequestExpiryRollback', 'actualKeyResponseExpiryRollback', 'actualKeyGrantExpiryRollback',
  'actualHTTPInvitationReceiptQuery', 'actualHTTPInvitationQueryAfterRestart',
  'actualInvitationCreationExpiryRollback', 'actualInvitationQueryExpiry', 'actualInvitationReturnExpiry'];
try {
  for (const relative of files) {
    const bytes = await verifiedLocalRead(path.join(root, relative)), target = path.join(directory, relative);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, bytes, { flag: 'wx', mode: 0o600 });
    if (!bytes.equals(await verifiedLocalRead(target)) || !bytes.equals(await verifiedLocalRead(path.join(root, relative)))) throw Error('source_changed_during_copy');
    manifest.files.push({ path: relative, bytes: bytes.length, sha256: digest(bytes) });
  }
  const config = await verifiedLocalRead(path.join(directory, files[3]));
  const configText = config.toString('utf8');
  if (!configText.includes('sockets = []') || !configText.includes('network = (allow = [])')
      || !configText.includes('globalOutbound = "no-network"') || !configText.includes('enableSql = true')) throw Error('offline_runtime_config_changed');
  await writeFile(path.join(directory, 'config.capnp'), config, { flag: 'wx', mode: 0o600 });
  const { build } = await import(pathToFileURL(options['--esbuild']).href);
  await build({ entryPoints: [path.join(directory, files[2])], outfile: path.join(directory, 'device-auth-workerd.bundle.mjs'),
    bundle: true, format: 'esm', platform: 'browser', target: 'es2022',
    external: ['cloudflare:workers'], nodePaths: [path.dirname(options['--jose'])], legalComments: 'eof', logLevel: 'warning' });
  manifest.bundleSHA256 = digest(await verifiedLocalRead(path.join(directory, 'device-auth-workerd.bundle.mjs')));
  // Two separate bounded processes, same isolated SQLite directory. Do NOT
  // combine entrypoint filters: phase two specifically checks process restart.
  for (const phase of ['phaseOne', 'phaseTwo']) {
    const logPath = path.join(directory, `${phase}.log`);
    const execution = spawnSync(options['--workerd'], ['test', `--directory-path=s2-qa-disk=${path.join(directory, 'db')}`,
      path.join(directory, 'config.capnp'), `s2-auth-qa:${phase}`],
    { encoding: 'utf8', timeout: 25_000, maxBuffer: 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe'] });
    const log = String(execution.stdout ?? '') + String(execution.stderr ?? '');
    if (execution.error || execution.status !== 0 || execution.signal) {
      await writeFile(logPath, log, { flag: 'wx', mode: 0o600 });
      manifest.phases.push({ phase, passed: false, log: path.basename(logPath) });
      throw Error(`offline_runtime_${phase}_failed`);
    }
    // Preserve stdout AND stderr. A zero exit is not enough: verify case
    // markers and a real framework PASS marker for this exact phase.
    await writeFile(logPath, log, { flag: 'wx', mode: 0o600 });
    const results = log.split('\n').filter(line => line.startsWith('{')).map(line => JSON.parse(line));
    if (!log.includes(`[ PASS ] s2-auth-qa:${phase}`) || !results.length
        || results.some(result => result.passed !== true || !expectedTests.includes(result.test))) throw Error('missing_runtime_case_markers');
    manifest.phases.push({ phase, passed: true, cases: results.map(result => result.test), log: path.basename(logPath), sha256: digest(Buffer.from(log)) });
  }
  const cases = manifest.phases.flatMap(phase => phase.cases);
  if (cases.length !== expectedTests.length || new Set(cases).size !== expectedTests.length
      || expectedTests.some(name => !cases.includes(name))) throw Error('runtime_case_coverage_incomplete');
  manifest.status = 'passed'; manifest.casesPassed = cases.length;
} catch (error) {
  manifest.status = 'failed'; manifest.failure = error instanceof Error ? error.message : 'unknown_failure';
  process.exitCode = 1;
} finally {
  manifest.finishedAt = new Date().toISOString();
  await writeFile(path.join(directory, 'result.json'), JSON.stringify(manifest, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
  console.log(JSON.stringify({ directory, status: manifest.status, casesPassed: manifest.casesPassed ?? 0,
    runtimeVersion: version, installedDependencies: false, liveCloudActions: 0 }));
}
