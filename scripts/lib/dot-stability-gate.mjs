// Release evidence, not an upstream latency promise. The owner accepts slow
// replies; timing-only success must never authorize a physical installation.
export const dotReleaseChecks = Object.freeze(['exactSendReceive', 'bidirectionalHistory',
  'deduplication', 'answerFreeContext', 'reconnectRecovery', 'cloudObservation24h',
  'simulatorRegression', 'securityMigration']);
export function dotStabilityGate(seconds, evidence = {}) {
  if (!Array.isArray(seconds) || evidence === null || typeof evidence !== 'object' || Array.isArray(evidence)) {
    return { passed: false, reason: 'invalid_release_evidence' };
  }
  if (seconds.length !== 6 || !seconds.every(n => Number.isFinite(n) && n >= 0)) {
    return { passed: false, reason: 'six_valid_timings_required' };
  }
  const sorted = [...seconds].sort((a, b) => a - b);
  const median = (sorted[2] + sorted[3]) / 2;
  const max = sorted[5];
  const missing = dotReleaseChecks.filter(key => evidence[key] !== true);
  return { passed: missing.length === 0, median, max, latencyInformationalOnly: true,
    missing, reason: missing.length ? 'release_evidence_incomplete' : 'release_evidence_complete',
    physicalInstallationAutomaticallyAuthorized: false };
}

export function receiptPollDelay(elapsedMs) {
  return elapsedMs < 90000 ? 1000 : 3000;
}
