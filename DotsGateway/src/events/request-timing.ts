// Server-generated per-request context, never a tool argument or a trusted
// client header. Missing legacy timing stays unknown rather than guessed.
export type MCPRequestTiming = { receivedAt: number; authorizedAt: number };
export function validRequestTiming(value: MCPRequestTiming | undefined, readAt: number): MCPRequestTiming | undefined {
  if (!value || !Number.isSafeInteger(value.receivedAt) || !Number.isSafeInteger(value.authorizedAt)
    || value.receivedAt < 0 || value.authorizedAt < value.receivedAt || value.authorizedAt > readAt) return undefined;
  return { receivedAt: value.receivedAt, authorizedAt: value.authorizedAt };
}

// Called only when an authenticated model tool actually receives a record.
// Device polling never calls this, and old missing timings stay unknown.
export function markRequestRead(storage: DurableObjectStorage, id: string, requestTiming?: MCPRequestTiming, now = Date.now()) {
  const timing = validRequestTiming(requestTiming, now);
  storage.sql.exec(`UPDATE message_timings SET
    mcp_received_at = CASE WHEN read_at IS NULL THEN ? ELSE mcp_received_at END,
    mcp_authorized_at = CASE WHEN read_at IS NULL THEN ? ELSE mcp_authorized_at END,
    read_at = COALESCE(read_at, ?) WHERE id = ?`, timing?.receivedAt ?? null, timing?.authorizedAt ?? null, now, id);
}
