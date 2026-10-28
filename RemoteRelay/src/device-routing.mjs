import { deviceRecords, DeviceAuthError } from "./device-auth.mjs";

export const DEVICE_PROTOCOL_HEADER = "X-Codex-Relay-Device-Protocol";
const id = value => typeof value === "string" && /^[A-Za-z0-9_-]{1,160}$/.test(value);
const keyID = value => typeof value === "string" && /^[a-f0-9]{32}$/.test(value);
const invalid = () => { throw new DeviceAuthError("invalid_device_route", 400); };

export function deviceRoute(request) {
  const url = new URL(request.url);
  if (url.protocol !== "https:" || url.username || url.password || url.hash) invalid();
  const match = /^\/v3\/rooms\/([A-Za-z0-9_-]{1,160})\/(snapshot|devices\/(?:invitations(?:\/[A-Za-z0-9_-]{1,160})?|enroll|me|peers|key-requests|me\/(?:key-request|room-key)|key-responses\/[A-Za-z0-9_-]{1,160}|[A-Za-z0-9_-]{1,160}\/revoke)|stream\/(?:mac|phone|watch)|mailbox\/(?:mac|phone|watch)(?:\/[A-Za-z0-9_-]{1,160})?)$/.exec(url.pathname);
  const epoch = request.headers.get("X-Codex-Relay-Key-ID");
  if (!match || !keyID(epoch)) invalid();
  const queries = [...url.searchParams];
  let cursor;
  if (queries.length) {
    if (request.method !== "GET" || !/^mailbox\/(mac|phone|watch)$/.test(match[2]) || queries.length !== 1
        || queries[0][0] !== "cursor" || !/^[0-9]{16}$/.test(queries[0][1])) invalid();
    cursor = queries[0][1];
  }
  return { roomID: match[1], keyID: epoch, resource: match[2], cursor, externalURL: request.url };
}

export function deviceRoots(raw, context) {
  const all = deviceRecords(raw);
  if (!all || !all.some(value => value.roomID === context.roomID && value.keyID === context.keyID && value.role === "mac")) {
    throw new DeviceAuthError("device_auth_not_configured", 503);
  }
  return raw;
}

// Non-secret coordinated-cutover policy. Invalid configuration fails closed;
// absence keeps current installed clients unchanged until a deliberate switch.
export function legacyDeviceUpgradeRequired(raw, roomID) {
  if (raw === undefined || raw === "") return false;
  let values; try { values = JSON.parse(raw); } catch { throw new DeviceAuthError("invalid_device_cutover_policy", 503); }
  if (!Array.isArray(values) || values.length > 64 || values.some(value => !id(value)) || new Set(values).size !== values.length) {
    throw new DeviceAuthError("invalid_device_cutover_policy", 503);
  }
  if (values.length && !id(roomID)) throw new DeviceAuthError("missing_legacy_room_context", 503);
  return values.includes(roomID);
}

export function deviceJSON(value, status = 200, extraHeaders = {}) {
  return new Response(value === undefined ? null : JSON.stringify(value), { status,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store",
      [DEVICE_PROTOCOL_HEADER]: "3", ...extraHeaders } });
}
export function deviceError(error) {
  return deviceJSON({ error: error instanceof DeviceAuthError ? error.code : "device_relay_unavailable" },
    error instanceof DeviceAuthError ? error.status : 503);
}
export function deviceAdmission(result) {
  return result.authorized === false ? deviceJSON({ error: "use_dpop_nonce" }, 401,
    { "DPoP-Nonce": result.nonce, "WWW-Authenticate": 'DPoP error="use_dpop_nonce"' }) : deviceJSON(result);
}

export async function forwardDeviceRequest(request, env) {
  try {
    const context = deviceRoute(request);
    deviceRoots(env.RELAY_DEVICE_ROOTS_V3, context);
    const headers = new Headers(request.headers);
    headers.set("X-Codex-Relay-Protocol", "3"); headers.set("X-Codex-Relay-Room", context.roomID);
    const name = `v3:${context.roomID}:${context.keyID}`;
    const stub = env.RELAY_ROOMS.get(env.RELAY_ROOMS.idFromName(name));
    // Keep the ACTUAL original target URI for proof verification in the DO.
    // Do not replace it with an untrusted forwarding header or suffix path.
    const result = await stub.fetch(new Request(request, { headers }));
    if (result?.headers?.get(DEVICE_PROTOCOL_HEADER) !== "3") {
      return deviceJSON({ error: "cloud_version_updating" }, 503);
    }
    return result;
  } catch (error) { return deviceError(error); }
}
