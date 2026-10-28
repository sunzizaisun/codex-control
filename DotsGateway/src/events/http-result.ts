import type { EventResult } from "./inbox";

export function eventResponse(result: EventResult) {
  // Global Worker and Durable Object rollout can briefly differ. An older
  // object may return undefined for a new operation: never call that success.
  const unavailable = result.ok && result.value === undefined;
  const status = unavailable ? 503 : result.ok ? 200 : result.status;
  const body = unavailable ? { error: "cloud_version_updating" } : result.ok ? result.value
    : { error: result.error, ...(result.retryAfter ? { retryAfter: result.retryAfter } : {}) };
  const response = Response.json(body, { status,
    headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" } });
  if (!result.ok && result.retryAfter) response.headers.set("Retry-After", String(result.retryAfter));
  return response;
}
