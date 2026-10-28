import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
import { test } from 'node:test';

test('controller fault constructors are compile-time isolated and never load a real queue or credentials', async () => {
  for (const filename of ['Apps/iOS/PhoneRelayController.swift', 'Apps/Watch/WatchRelayController.swift']) {
    const source = await readFile(new URL('../../' + filename, import.meta.url), 'utf8');
    assert.match(source, /#if CONTROLLER_FAULT_TESTS\s*private let commandFaultEnvironment|#if CONTROLLER_FAULT_TESTS\s*\/\/[^]*?private let commandFaultEnvironment/);
    assert.match(source, /override init\(\) \{\s*#if CONTROLLER_FAULT_TESTS\s*guard let environment = commandFaultEnvironment else \{ fatalError/);
    assert.match(source, /snapshot = environment\.snapshot\s*loadCommandOutbox\(\)\s*#else/);
    assert.match(source, /private var commandStore: CommandOutboxFileStore \{\s*#if CONTROLLER_FAULT_TESTS\s*return commandFaultEnvironment!\.store/);
    assert.match(source, /#if CONTROLLER_FAULT_TESTS\s*let records = try commandStore\.load\(\)\s*#else/);
    assert.match(source, /private func startRemotePolling\(\) \{\s*#if CONTROLLER_FAULT_TESTS\s*return/);
    assert.match(source, /for record in records \{\s*commandReceipts\.record\(\.unconfirmed\(CommandRecovery\.unconfirmedText\), for: record\.messageID\)/);
  }
});

test('native fault harness refuses physical targets and uses only synthetic fixed-simulator data', async () => {
  const host = await readFile(new URL('../../Tests/Fixtures/ControllerFaultHost.swift', import.meta.url), 'utf8');
  const environment = await readFile(new URL('../../Tests/Controllers/ControllerCommandFaultEnvironment.swift', import.meta.url), 'utf8');
  const tests = await readFile(new URL('../../Tests/Controllers/ControllerCommandDeliveryTests.swift', import.meta.url), 'utf8');
  assert.match(host, /#if !targetEnvironment\(simulator\)\s*#error/);
  assert.match(environment, /#if !CONTROLLER_FAULT_TESTS \|\| !targetEnvironment\(simulator\)\s*#error/);
  assert(environment.includes('FileManager.default.temporaryDirectory'));
  assert(environment.includes('try RelayCredentials.generate()'));
  assert(environment.includes('relay-controller-fixture.invalid'));
  assert(!/fromMainBundle|RelayCredentialStore|standard\.data\(/.test(environment));
  assert(tests.includes('BF2EAE23-2D12-49FD-9CAE-990D87D818FE'));
  assert(tests.includes('37147111-8F9F-430E-92F1-E08D8CD8B617'));
  assert(tests.includes('SIMULATOR_UDID'));
  assert(!tests.includes('override func setUpWithError'));
});

test('relay request dependency injection preserves the original default session and cannot use the Mac fallback', async () => {
  const source = await readFile(new URL('../../Sources/CodexWatchCore/RemoteRelayClient.swift', import.meta.url), 'utf8');
  assert(source.includes('requestTransport: RequestTransport? = nil'));
  assert(source.includes('self.session = .shared'));
  assert(source.includes('RelayTransportPolicy.watchSessionConfiguration('));
  assert(source.includes('if requestTransport == nil, error is URLError'));
  assert.match(source, /if let requestTransport \{[^]*?try await requestTransport\(request\)[^]*?\} else \{\s*\(data, response\) = try await session\.data\(for: request, delegate: RelayNoRedirectDelegate\.shared\)/);
});

test('offline mac preview cannot lease the production action journal or start transports', async () => {
  const source = await readFile(new URL('../../Apps/Mac/MacBridgeViewModel.swift', import.meta.url), 'utf8');
  assert.match(source, /let preview = ProcessInfo\.processInfo\.arguments\.contains\("-UIPreview"\)/);
  assert.match(source, /persistenceURL: preview \? nil : BridgeMessageDeduplicator\.defaultJournalURL/);
  assert.match(source, /func start\(\) \{[\s\S]*?guard !isUIPreview else \{ return \}[\s\S]*?configureCompanionTransports\(\)/);
});

test('a deallocated Mac command endpoint cannot silently return a successful acceptance', async () => {
  const source = await readFile(new URL('../../Apps/Mac/MacBridgeViewModel.swift', import.meta.url), 'utf8');
  const guarded = source.match(/commandHandler:\s*\{ \[weak self\] command in\s*guard let self else \{ throw AppServerClientError\.notRunning \}/g) ?? [];
  assert.equal(guarded.length, 3);
});

test('a reset acknowledgement without a known result never defaults to successful consumption', async () => {
  for (const filename of ['Apps/iOS/PhoneRelayController.swift', 'Apps/Watch/WatchRelayController.swift']) {
    const source = await readFile(new URL('../../' + filename, import.meta.url), 'utf8');
    assert(source.includes('usageResetResult = UsageResetOutcome.confirmedResponse(envelope.message)'));
    assert(!/usageResetResult\s*=\s*envelope\.message\s*\?\?\s*"reset"/.test(source));
  }
});

test('QA preference resets are limited to debug offline simulator launches', async () => {
  for (const filename of ['Apps/iOS/CodexRelayApp.swift', 'Apps/Watch/CodexWatchApp.swift']) {
    const source = await readFile(new URL('../../' + filename, import.meta.url), 'utf8');
    assert.match(source, /#if DEBUG && targetEnvironment\(simulator\)[\s\S]*?if args\.contains\("-UIPreview"\) && args\.contains\("-QAResetPreferences"\)/);
    assert.match(source, /UserDefaults\.standard\.set\(AppLanguage\.english\.rawValue, forKey: AppPreferenceKeys\.language\)/);
    assert.match(source, /UserDefaults\.standard\.set\(AppAppearance\.light\.rawValue, forKey: AppPreferenceKeys\.appearance\)/);
  }
});

test('native UI smoke requires the fixed QA UUID and never launches a production cloud mode', async () => {
  const source = await readFile(new URL('../../Tests/Interface/CodexRelayInterfaceTests.swift', import.meta.url), 'utf8');
  assert.match(source, /#if targetEnvironment\(simulator\)/);
  assert.match(source, /environment\["SIMULATOR_UDID"\]\?\.uppercased\(\) == expectedSimulator/);
  assert(source.includes('BF2EAE23-2D12-49FD-9CAE-990D87D818FE'));
  assert(source.includes('37147111-8F9F-430E-92F1-E08D8CD8B617'));
  assert.match(source, /launchArguments = \["-UIPreview", route, "-QAResetPreferences"\]/);
  assert.match(source, /guard \["-PreviewSettings", "-PreviewNewCodex", "-PreviewDashboard", "-PreviewDots", "-PreviewTaskDetail"\]\.contains\(route\)/);
  assert(!source.includes('-PreviewDotsShared'));
});

test('uncertain commands are persisted stopped and bypass both automatic command retry paths', async () => {
  const storage = await readFile(new URL('../../Sources/CodexWatchCore/CommandOutboxStore.swift', import.meta.url), 'utf8');
  assert.match(storage, /var stopped = record; stopped\.stopped = true/);
  for (const filename of ['Apps/iOS/PhoneRelayController.swift', 'Apps/Watch/WatchRelayController.swift']) {
    const source = await readFile(new URL('../../' + filename, import.meta.url), 'utf8');
    assert.match(source, /typealias PendingCommandRecord = StoredCommandRecord/);
    assert.match(source, /for record in commandOutbox\.values where record\.stopped != true/);
    assert.match(source, /guard commandMaySend\(envelope\) else \{ return \}/);
    assert.match(source, /CommandRecovery\.shouldPause\(record\.(?:data|envelopeData)/);
    assert.match(source, /private func persistCommandOutbox\(\) -> Bool \{\s*guard !isUIPreview \|\| commandStorageQASessionID != nil else \{ return true \}/);
    assert(!/prompt: trimmed/.test(source));
  }
});

test('local storage QA cannot choose arbitrary paths, read legacy preferences or start live transports', async () => {
  for (const filename of ['Apps/iOS/PhoneRelayController.swift', 'Apps/Watch/WatchRelayController.swift']) {
    const source = await readFile(new URL('../../' + filename, import.meta.url), 'utf8');
    assert.match(source, /#if DEBUG && targetEnvironment\(simulator\)\s*let args = ProcessInfo\.processInfo\.arguments\s*guard isUIPreview/);
    assert(source.includes('UUID(uuidString: args[index + 1])'));
    assert(source.includes('appendingPathComponent("QA", isDirectory: true)'));
    assert(source.includes('legacyData: isUIPreview ? nil : UserDefaults.standard.data(forKey: Self.commandOutboxKey)'));
    assert.match(source, /func start\(\)[\s\S]*?if isUIPreview \{/);
  }
});

test('task commands require durable admission before either client transport and refuse unreadable storage', async () => {
  for (const filename of ['Apps/iOS/PhoneRelayController.swift', 'Apps/Watch/WatchRelayController.swift']) {
    const source = await readFile(new URL('../../' + filename, import.meta.url), 'utf8');
    assert.match(source, /guard commandStorageAvailable else \{ return false \}/);
    assert.match(source, /guard !commandStorageReadFailed else \{ markCommandStorageUnavailable\(\); return false \}/);
    const admission = source.includes('private func acceptCommand')
      ? source.slice(source.indexOf('private func acceptCommand'), source.indexOf('private func acceptDecisionFromWatch'))
      : source.slice(source.indexOf('private func queueCommand'), source.indexOf('private func handle('));
    assert.match(admission, /guard commandStorageAvailable else/);
    assert.match(admission, /(?:encoded|data)\.count <= CommandRecovery\.maximumStoredBytes/);
    assert.match(admission, /guard CommandRecovery\.original\((?:encoded|data)\) != nil/);
    assert.match(admission, /guard persistCommandOutbox\(\) else \{[\s\S]*?return(?: envelope\.messageID)?\s*\}/);
    const persist = admission.indexOf('guard persistCommandOutbox()');
    assert(persist >= 0);
    const send = admission.indexOf(source.includes('private func acceptCommand') ? 'sendToMac(envelope, urgent: true)' : 'send(envelope, queueIfUnreachable: true)');
    assert(send > persist);
  }
});

test('both command forms keep their draft if a confirmed local discard cannot be saved', async () => {
  for (const filename of ['Apps/iOS/PhoneDashboardView.swift', 'Apps/Watch/WatchDashboardView.swift']) {
    const source = await readFile(new URL('../../' + filename, import.meta.url), 'utf8');
    assert.equal((source.match(/guard relay\.discardUnconfirmedCommand\(draft\.submissionID\) else \{ return \}/g) ?? []).length, 2);
  }
});

test('independent review has no executable-send API and preserves an edited caller draft', async () => {
  const view = await readFile(new URL('../../Sources/CodexWatchCore/CommandReviewView.swift', import.meta.url), 'utf8');
  assert(view.includes('@ObservedObject private var source: Source'));
  assert(view.includes('original.verifiedPrompt'));
  assert(view.includes('state.isPending'));
  assert(view.includes('canCheck: original.verifiedPrompt != nil'));
  assert(!/startCodexChat|sendCommand|taskCommand\(/.test(view));
  for (const filename of ['Apps/iOS/PhoneDashboardView.swift', 'Apps/Watch/WatchDashboardView.swift']) {
    const source = await readFile(new URL('../../' + filename, import.meta.url), 'utf8');
    assert.equal((source.match(/if draft\.submissionID == id \{ draft\.discardPendingOriginal\(\) \}/g) ?? []).length, 2);
    assert.equal((source.match(/CommandRecoveryReviewView\(source: relay, original: original/g) ?? []).length, 2);
  }
  for (const filename of ['Apps/iOS/PhoneRelayController.swift', 'Apps/Watch/WatchRelayController.swift']) {
    const source = await readFile(new URL('../../' + filename, import.meta.url), 'utf8');
    const start = source.indexOf('func checkCommandStatus(_ id: String?)');
    const body = source.slice(start, source.indexOf('\n    }', start));
    assert(body.includes('original.messageID == record.messageID'));
  }
});

test('repair requires explicit isolated confirmation and never initiates command transport', async () => {
  for (const filename of ['Apps/iOS/PhoneRelayController.swift', 'Apps/Watch/WatchRelayController.swift']) {
    const source = await readFile(new URL('../../' + filename, import.meta.url), 'utf8');
    const start = source.indexOf('func repairCommandStorage() -> Bool');
    const body = source.slice(start, source.indexOf('\n    }', start));
    assert(start >= 0);
    assert(body.includes('guard commandStorageRepairNeeded, !isUIPreview || commandStorageQASessionID != nil'));
    assert(body.includes('commandStore.quarantineAndRebuild'));
    assert(!/sendToMac|enqueueForRemoteDelivery|queueCommand|sendCommand/.test(body));
  }
  const repair = await readFile(new URL('../../Sources/CodexWatchCore/CommandOutboxRepair.swift', import.meta.url), 'utf8');
  assert(repair.indexOf('guard try readRepairSource(backup) == original') < repair.indexOf('try save(records)'));
  assert(repair.includes('guard try readRepairSource(fileURL) == original'));
  assert(repair.includes('first.stopped = true'));
});

test('phone forwards read-only Watch queries instead of consuming them as a dashboard request', async () => {
  const source = await readFile(new URL('../../Apps/iOS/PhoneRelayController.swift', import.meta.url), 'utf8');
  assert.match(source, /envelope\.taskHistoryRequest == nil, envelope\.commandStatusQuery == nil else/);
  assert.match(source, /envelope\.taskHistoryRequest != nil \|\| envelope\.commandStatusQuery != nil/);
  assert.match(source, /if envelope\.commandStatusQuery != nil \{\s*guard let original = envelope\.commandStatusQuery\?\.validatedOriginal\(for: envelope\) else \{ return \}/);
  assert(source.includes('commandStatusQueries.trackForwarded(envelope, expectedOriginalData: known.envelopeData)'));
  assert(source.includes('CommandRecovery.requiresLocalReview(senderDeviceID: envelope.senderDeviceID, localDeviceID: deviceID'));
});

test('offline phone preview does not provision production relay credentials or refresh its mailbox', async () => {
  const source = await readFile(new URL('../../Apps/iOS/PhoneRelayController.swift', import.meta.url), 'utf8');
  assert.match(source, /if !isUIPreview, let configuration = RemoteRelayConfiguration\.fromMainBundle\(\)/);
  assert.match(source, /func requestLatestSnapshot\(\) \{\s*guard !isUIPreview else \{ return \}/);
});

test('offline watch preview blocks both refresh entry points and credential provisioning', async () => {
  const source = await readFile(new URL('../../Apps/Watch/WatchRelayController.swift', import.meta.url), 'utf8');
  assert.match(source, /if !isUIPreview, let configuration = RemoteRelayConfiguration\.fromMainBundle\(\)/);
  assert.match(source, /func refresh\(\) \{\s*guard !isUIPreview else \{ return \}/);
  assert.match(source, /private func refreshRemoteNow\(\) async \{\s*guard !isUIPreview else \{ return \}/);
});

test('opening dot from an offline preview cannot read real drafts or contact the real gateway', async () => {
  const source = await readFile(new URL('../../Sources/CodexWatchCore/DotsViews.swift', import.meta.url), 'utf8');
  assert.match(source, /private enum DotViewStore/);
  assert.match(source, /arguments\.contains\("-UIPreview"\)/);
  assert.match(source, /UserDefaults\(suiteName: "CodexControl\.dot\.offline-preview"\)/);
  assert.match(source, /DotsStore\(thread: thread, configuration: nil, defaults: defaults\)/);
  assert.equal((source.match(/DotViewStore\.make\(/g) || []).length, 2);
});
