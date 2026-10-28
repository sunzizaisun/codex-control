import { constantTimeEqual } from "./packet.mjs";

export const validRelayRoomID = value => typeof value === "string" && /^[A-Za-z0-9_-]{1,160}$/.test(value);

// Server records contain bearer authentication only. Reject accidental
// uploads of device encryption keys or bootstrap secrets rather than storing
// an object whose confidentiality properties depend on operator convention.
export function relayV2Records(raw) {
  let records;
  try { records = JSON.parse(raw); } catch { return null; }
  if (!Array.isArray(records) || !records.length || records.length > 16) return null;
  const seen = new Set();
  for (const entry of records) {
    if (!entry || Object.keys(entry).sort().join(",") !== "authToken,keyID,roomID"
      || typeof entry.roomID !== "string" || typeof entry.keyID !== "string" || typeof entry.authToken !== "string"
      || !validRelayRoomID(entry.roomID)
      || !/^[a-f0-9]{32}$/.test(entry.keyID)
      || !/^[A-Za-z0-9+/]{43}=$/.test(entry.authToken)
      || seen.has(`${entry.roomID}:${entry.keyID}`)) return null;
    seen.add(`${entry.roomID}:${entry.keyID}`);
  }
  return records;
}

export function authorizeRelayV2(raw, roomID, keyID, token) {
  const records = relayV2Records(raw);
  if (!records) return { configured: false, authorized: false };
  const record = records.find(value => value.roomID === roomID && value.keyID === keyID);
  return { configured: true, authorized: !!record && constantTimeEqual(token, record.authToken) };
}
