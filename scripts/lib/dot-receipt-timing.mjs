// Server timestamps only. Device render latency is a separate UI measurement.
export function dotReceiptTiming(receipt) {
  const timing = receipt.timing ?? {};
  const seconds = (end, start) => Number.isFinite(end) && Number.isFinite(start)
    && start >= 0 && end >= start ? (end - start) / 1000 : null;
  return {
    queueSeconds: seconds(timing.dispatchedAt, timing.acceptedAt),
    callbackSeconds: seconds(timing.acknowledgedAt, timing.dispatchedAt),
    // Includes official scheduling AND any work before the first inbox read.
    afterCallbackToReadSeconds: seconds(timing.readAt, timing.acknowledgedAt),
    // Additive trusted ingress measurements are present only on newly read
    // messages. Do not backfill or reinterpret the older aggregate interval.
    ...(timing.mcpReceivedAt !== undefined || timing.mcpAuthorizedAt !== undefined ? {
      afterCallbackToMCPIngressSeconds: seconds(timing.mcpReceivedAt, timing.acknowledgedAt),
      mcpAuthorizationSeconds: seconds(timing.mcpAuthorizedAt, timing.mcpReceivedAt),
      mcpAuthorizedToReadSeconds: seconds(timing.readAt, timing.mcpAuthorizedAt),
    } : {}),
    // Includes reasoning and tool work, not just model generation.
    readToReplySeconds: seconds(receipt.repliedAt, timing.readAt),
    serverSeconds: seconds(receipt.repliedAt, timing.acceptedAt),
  };
}
