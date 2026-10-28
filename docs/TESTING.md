# Testing

## Offline checks

On macOS with full Xcode selected:

```sh
swift test --filter CodexWatchCoreTests
swift test --filter CodexBridgeKitTests
node --test scripts/test/*.test.mjs
node scripts/scan-public-source.mjs
```

Cloudflare and relay tests use synthetic fixtures:

```sh
cd RemoteRelay
npm ci --ignore-scripts
npm test
cd ../DotsGateway
npm ci --ignore-scripts
npm run check
npm run check:events
npm test
npm run test:events
npx vitest run --config vitest.oauth.config.ts
```

Deno:

```sh
cd DotsCallbackRelay
deno task check
deno task test
deno task test:native
```

`test:native` only permits loopback networking. The public-edge manual TLS probe is separate and is not part of the default task. Fixture keys must never become deployment keys.

## Native platform tests

The XcodeGen recipes in `scripts/*tests.yml` build isolated Core, controller-fault, UI, and protected-Keychain hosts. Some test guards intentionally require designated simulator IDs. Create dedicated simulators and update those guards together with their isolation assertions; never replace them with a physical-device destination. Mac protected-Keychain tests require your own valid signing profile and Keychain access group.

Simulator/unit results are not physical Face ID, wrist detection, APNs, background scheduling, or real server acceptance. Use a separate user-approved hardware plan for those.

## Real cloud acceptance: explicit opt-in

`node scripts/run-dot-portable-qa.mjs --plan` is safe and sends nothing. `--run-four` requires a dedicated device key and explicit HTTPS origin supplied through environment variables. It can submit at most four new synthetic messages, verifies replies and context, and stops on uncertainty. Do not repeat a POST merely because a response was lost.

```sh
DOT_QA_ORIGIN=https://YOUR-DOT-INBOX-HOST \
DOT_QA_DEVICE_KEY=YOUR-DEDICATED-DEVICE-KEY \
node scripts/run-dot-portable-qa.mjs --run-four
```

Do not paste real keys into shell history: set them privately in your own environment/secret store instead. The command above describes names, not real values. A live result must identify the original submitted IDs and actual dot replies; a manually written answer does not count. Read only the explicitly authorized room and at most its last 30 text messages.

CI runs offline checks only. It has read-only repository permissions, no deployment credentials, no live message tests, and no device installation steps.
