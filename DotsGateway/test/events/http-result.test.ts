import { expect, it } from "vitest";
import { eventResponse } from "../../src/events/http-result";
it("rejects an old DO's undefined result rather than returning invalid JSON success", async () => {
  const response = eventResponse({ ok: true, value: undefined });
  expect(response.status).toBe(503);
  expect(await response.json()).toEqual({ error: "cloud_version_updating" });
  expect(response.headers.get("Cache-Control")).toBe("no-store");
});
it("preserves successful receipts and machine-readable retry hints", async () => {
  const result = { id: "fixture", state: "completed" };
  const success = eventResponse({ ok: true, value: result });
  expect(success.status).toBe(200); expect(await success.json()).toEqual(result);
  const failure = eventResponse({ ok: false, status: 503, rpcCode: -32603, error: "cloud_read_quota_exhausted", retryAfter: 900 });
  expect(failure.status).toBe(503); expect(failure.headers.get("Retry-After")).toBe("900");
  expect(await failure.json()).toEqual({ error: "cloud_read_quota_exhausted", retryAfter: 900 });
});
