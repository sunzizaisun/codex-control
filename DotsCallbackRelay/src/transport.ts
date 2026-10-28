import { Buffer } from "node:buffer";
import ipaddr from "ipaddr.js";
import { HTTPParser } from "http-parser-js";
import { EventError } from "./errors.ts";

export function publicAddress(raw: string) {
  try { const address = ipaddr.parse(raw); return !raw.includes("%") && address.range() === "unicast"; }
  catch { return false; }
}
// Published Cloudflare proxy ranges (checked 2026-10-07):
// https://www.cloudflare.com/ips-v4/ and /ips-v6/ . Workers TCP sockets cannot
// connect to these ranges. This is an availability check, not an SSRF allowlist.
const cloudflareRanges = [
  "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
  "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
  "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
  "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22", "2400:cb00::/32",
  "2606:4700::/32", "2803:f800::/32", "2405:b500::/32", "2405:8100::/32",
  "2a06:98c0::/29", "2c0f:f248::/32",
].map(cidr => ipaddr.parseCIDR(cidr));
export function cloudflareAddress(raw: string) {
  try {
    const address = ipaddr.parse(raw);
    return cloudflareRanges.some(([base, mask]) => base.kind() === address.kind() && address.match(base, mask));
  } catch { return false; }
}
function addressKind(raw: unknown) {
  if (typeof raw !== "string") return "non_string";
  try {
    const range = ipaddr.parse(raw).range();
    const known = ["unicast", "unspecified", "broadcast", "multicast", "linkLocal", "loopback", "carrierGradeNat", "private", "reserved", "ipv4Mapped", "uniqueLocal", "rfc6052", "rfc6145", "6to4", "teredo", "as112", "amt", "benchmarking", "orchid2", "deprecated"];
    return known.includes(range) ? range : "other_non_public";
  } catch { return "invalid_address"; }
}
export function callbackURL(raw: string) {
  let url: URL;
  try { url = new URL(raw); } catch { throw new EventError("callback_blocked", -32015, 400, "callback_url"); }
  if (url.protocol !== "https:" || url.username || url.password || url.hash || url.port
    || url.hostname.endsWith(".invalid") || url.hostname.endsWith(".local") || url.hostname === "localhost") {
    throw new EventError("callback_blocked", -32015, 400, "callback_url");
  }
  return url;
}
export type DeliverySocket = {
  opened: Promise<unknown>;
  closed: Promise<unknown>;
  readable: ReadableStream<Uint8Array>;
  writable: WritableStream<Uint8Array>;
  startTls(options: { expectedServerHostname: string }): DeliverySocket;
  close(): Promise<void>;
};
export type DeliveryIO = {
  resolve(hostname: string): Promise<string[]>;
  connect(address: { hostname: string; port: number }, options: { secureTransport: "starttls"; allowHalfOpen: false }): DeliverySocket;
  selectAddress?(addresses: string[]): string;
};
async function deadline<T>(operation: Promise<T>, millis: number) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new EventError("timeout", -32015, 503)), millis); });
  try { return await Promise.race([operation, timeout]); }
  finally { clearTimeout(timer); }
}
// Resolve once, refuse any non-public answer, connect to the chosen IP, and
// verify TLS against the ORIGINAL hostname. No second hostname DNS lookup.
// There is intentionally no fallback to an unpinned fetch on socket failure.
export async function pinnedPost(raw: string, body: string, headers: Record<string, string>, io: DeliveryIO): Promise<Response> {
  const url = callbackURL(raw);
  const addresses = await deadline(io.resolve(url.hostname), 10_000);
  if (!addresses.length) throw new EventError("callback_blocked", -32015, 400, "callback_dns_empty");
  if (addresses.some(address => !publicAddress(address))) {
    const error = new EventError("callback_blocked", -32015, 400, "callback_address_blocked");
    // Public category names only, never the returned IPs or destination URL.
    error.addressKinds = addresses.slice(0, 16).map(addressKind);
    throw error;
  }
  // Any alternative must come from the same fully validated DNS answer set.
  // Do not replace an unsupported socket route with an unpinned fetch.
  const address = io.selectAddress ? io.selectAddress(addresses) : addresses[0];
  if (!addresses.includes(address)) throw new EventError("callback_blocked", -32015, 400, "callback_address_blocked");
  let socket: DeliverySocket;
  try { socket = io.connect({ hostname: address, port: 443 }, { secureTransport: "starttls", allowHalfOpen: false }); }
  catch { throw new EventError("callback_connection_failed", -32015, 503, "callback_tcp"); }
  void socket.closed.catch(() => {});
  let secure: DeliverySocket | undefined;
  let phase: "callback_tcp" | "callback_tls" | "callback_http" = "callback_tcp";
  try {
    await deadline(socket.opened, 10_000);
    phase = "callback_tls";
    secure = socket.startTls({ expectedServerHostname: url.hostname.replace(/^\[|\]$/g, "") });
    void secure.closed.catch(() => {});
    const connection = secure;
    return await deadline((async () => {
      await connection.opened;
      phase = "callback_http";
      const bytes = new TextEncoder().encode(body);
      if (bytes.byteLength > 262144) throw new EventError("payload_too_large", -32602, 413);
      const fields = { ...headers, Host: url.host, Connection: "close", "Content-Length": String(bytes.byteLength), "Accept-Encoding": "identity" };
      if (Object.entries(fields).some(([key, value]) => !/^[A-Za-z0-9-]+$/.test(key) || /[\r\n]/.test(value))) throw new EventError("invalid_headers");
      const head = new TextEncoder().encode(`POST ${url.pathname}${url.search} HTTP/1.1\r\n${Object.entries(fields).map(([key, value]) => `${key}: ${value}\r\n`).join("")}\r\n`);
      const writer = connection.writable.getWriter();
      try { await writer.write(head); await writer.write(bytes); } finally { writer.releaseLock(); }
      const parser = new HTTPParser(HTTPParser.RESPONSE); parser.maxHeaderSize = 16384;
      let status = 0, complete = false, length = 0, total = 0;
      let headerLength = 0, delimiter = 0, headerEnded = false;
      const chunks: Buffer[] = [];
      parser[HTTPParser.kOnHeadersComplete] = info => {
        if (info.statusCode < 200) throw new EventError("callback_invalid_response", -32015, 502);
        status = info.statusCode;
        if (info.upgrade) throw new EventError("callback_invalid_response", -32015, 502);
      };
      parser[HTTPParser.kOnBody] = (chunk, offset, size) => {
        length += size;
        if (length > 8192) throw new EventError("callback_response_too_large", -32015, 502);
        chunks.push(Buffer.from(chunk.subarray(offset, offset + size)));
      };
      parser[HTTPParser.kOnMessageComplete] = () => { if (complete) throw new EventError("callback_invalid_response", -32015, 502); complete = true; };
      const reader = connection.readable.getReader();
      try {
        while (!complete) {
          const chunk = await reader.read();
          if (chunk.done) { const error = parser.finish(); if (error) throw error; break; }
          total += chunk.value.byteLength;
          if (total > 65536) throw new EventError("callback_response_too_large", -32015, 502);
          // The parser's limit counts after parsing a buffer and resets at
          // message completion. Independently bound the raw first header,
          // including when the whole HTTP response arrives in one packet.
          if (!headerEnded) for (const byte of chunk.value) {
            headerLength++;
            if (headerLength > 16384) throw new EventError("callback_response_too_large", -32015, 502);
            const expected = delimiter % 2 === 0 ? 13 : 10;
            delimiter = byte === expected ? delimiter + 1 : byte === 13 ? 1 : 0;
            if (delimiter === 4) { headerEnded = true; break; }
          }
          const result = parser.execute(Buffer.from(chunk.value)); if (result instanceof Error) throw result;
        }
      } finally { reader.releaseLock(); parser.close(); }
      if (!headerEnded || !complete || status < 200 || status > 599) throw new EventError("callback_invalid_response", -32015, 502);
      const payload = Buffer.concat(chunks);
      return new Response([204, 205, 304].includes(status) ? null : payload, { status });
    })(), 10_000);
  } catch (error) {
    if (error instanceof EventError) throw error;
    throw new EventError("callback_connection_failed", -32015, 503, phase);
  } finally { await (secure || socket).close().catch(() => {}); }
}
