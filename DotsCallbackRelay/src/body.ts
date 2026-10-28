import { EventError } from "./errors.ts";
export async function boundedBytes(body: ReadableStream<Uint8Array> | null, max: number, signal?: AbortSignal): Promise<Uint8Array> {
  if (!body) throw new EventError("empty_body");
  const reader = body.getReader(), chunks: Uint8Array[] = [];
  const stop = () => { void reader.cancel().catch(() => {}); };
  signal?.addEventListener("abort", stop, { once: true });
  let length = 0;
  try {
    for (;;) {
      signal?.throwIfAborted();
      const part = await reader.read(); signal?.throwIfAborted(); if (part.done) break;
      length += part.value.byteLength;
      if (length > max) { await reader.cancel(); throw new EventError("body_too_large", -32602, 413); }
      chunks.push(part.value);
    }
  } finally { signal?.removeEventListener("abort", stop); reader.releaseLock(); }
  const bytes = new Uint8Array(length); let at = 0;
  for (const chunk of chunks) { bytes.set(chunk, at); at += chunk.byteLength; }
  return bytes;
}
export async function boundedJSON(body: ReadableStream<Uint8Array> | null, max: number): Promise<unknown> {
  const bytes = await boundedBytes(body, max);
  try { return JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)); }
  catch { throw new EventError("invalid_json"); }
}
