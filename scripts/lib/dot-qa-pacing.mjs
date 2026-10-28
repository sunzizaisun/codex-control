// Diagnostic-only spacing, never a native-app send delay or latency fix.
// The quiet interval does not prove the upstream task is idle.
export function qaSettleDelay(roundIndex, enabled = false) {
  if (!Number.isInteger(roundIndex) || roundIndex < 0 || roundIndex > 5 || typeof enabled !== 'boolean') {
    throw new Error('invalid_qa_pacing');
  }
  return enabled && (roundIndex === 2 || roundIndex === 4) ? 30000 : 0;
}
