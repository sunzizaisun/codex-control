// Match only the confirmed platform error, never expose exception messages.
export function durableReadQuotaFailure(error: unknown, now = Date.now()) {
  if (!(error instanceof Error) || !error.message.includes("Exceeded allowed rows read in Durable Objects free tier")) return undefined;
  const nextReset = (Math.floor(now / 86400_000) + 1) * 86400_000;
  return { error: "cloud_read_quota_exhausted", status: 503, rpcCode: -32603,
    // A quota response just after midnight must not suppress readiness checks
    // for another entire day. This is a bounded READ probe cooldown, not a
    // promise that the provider has reset or permission to resend a POST.
    retryAfter: Math.max(1, Math.min(900, Math.ceil((nextReset - now) / 1000))) };
}
