import { bodyHash, DeviceAuthError } from "./device-auth.mjs";

// Shared bounded UTF-8 reader. No caller logs plaintext or substitutes a
// re-encoded object's hash for the bytes actually covered by the proof.
export async function readDeviceJSON(request, maximumBytes = 8192, prefix = "device") {
  const fail = (suffix, status) => { throw new DeviceAuthError(`${prefix}_${suffix}`, status); };
  if (Number(request.headers.get("Content-Length")) > maximumBytes) fail("body_too_large", 413);
  if (!request.body) fail("invalid_body", 400);
  const reader = request.body.getReader(), chunks = []; let size = 0;
  try {
    while (true) {
      const { value, done } = await reader.read(); if (done) break;
      size += value.byteLength;
      if (size > maximumBytes) { await reader.cancel(); fail("body_too_large", 413); }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    const value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    return { value, bytes, bodyDigest: await bodyHash(bytes) };
  } catch (error) {
    if (error instanceof DeviceAuthError) throw error;
    fail("invalid_body", 400);
  } finally { reader.releaseLock(); }
}
