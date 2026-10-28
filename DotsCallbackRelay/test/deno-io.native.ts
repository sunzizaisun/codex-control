// Native adapter regression, intentionally separate from permission-free unit
// tests. Loopback is used only by this fixture; production SSRF guards remain
// enabled and do not accept loopback callback addresses.
import { strict as assert } from "node:assert";
import { denoIO } from "../src/deno-io.ts";

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const connectOptions = { secureTransport: "starttls" as const, allowHalfOpen: false as const };
async function bounded<T>(promise: Promise<T>): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([promise, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("native fixture timeout")), 3_000);
    })]);
  } finally { clearTimeout(timer); }
}
async function writeAll(conn: Deno.Conn, bytes: Uint8Array) {
  let offset = 0;
  while (offset < bytes.length) offset += await conn.write(bytes.subarray(offset));
}

Deno.test("native TCP adapter preserves Unicode and closes without leaked resources", async () => {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const payload = encoder.encode("原生网络：海狸-428🍁，中文🦦");
  const server = (async () => {
    const conn = await listener.accept();
    try {
      const bytes = new Uint8Array(payload.length);
      let offset = 0;
      while (offset < bytes.length) {
        const size = await conn.read(bytes.subarray(offset));
        assert.notEqual(size, null); offset += size!;
      }
      assert.deepEqual(bytes, payload);
      await writeAll(conn, bytes);
    } finally { conn.close(); }
  })();
  const socket = denoIO.connect({ hostname: "127.0.0.1", port: listener.addr.port }, connectOptions);
  try {
    await bounded(socket.opened);
    const writer = socket.writable.getWriter();
    try { await bounded(writer.write(payload)); } finally { writer.releaseLock(); }
    const reader = socket.readable.getReader();
    const chunks: number[] = [];
    try {
      for (;;) {
        const chunk = await bounded(reader.read());
        if (chunk.done) break;
        chunks.push(...chunk.value);
      }
    } finally { reader.releaseLock(); }
    assert.equal(decoder.decode(new Uint8Array(chunks)), decoder.decode(payload));
    await bounded(server);
  } finally { await socket.close(); listener.close(); }
  await bounded(socket.closed);
});

Deno.test("native close during TCP opening closes a late connection", async () => {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const accepted = listener.accept();
  const socket = denoIO.connect({ hostname: "127.0.0.1", port: listener.addr.port }, connectOptions);
  try {
    const rejected = assert.rejects(bounded(socket.opened), /closed/);
    await socket.close();
    const conn = await bounded(accepted);
    try { assert.equal(await bounded(conn.read(new Uint8Array(1))), null); }
    finally { conn.close(); }
    await rejected;
    await bounded(socket.closed);
  } finally { await socket.close(); listener.close(); }
});

Deno.test("native TLS handshake rejects a plaintext peer before application writes", async () => {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const server = (async () => {
    const conn = await listener.accept();
    try {
      const bytes = new Uint8Array(4096);
      const size = await bounded(conn.read(bytes));
      assert.ok(size && size > 0);
      assert.equal(bytes[0], 22); // TLS ClientHello, never the message body.
      await writeAll(conn, encoder.encode("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"));
    } finally { conn.close(); }
  })();
  const socket = denoIO.connect({ hostname: "127.0.0.1", port: listener.addr.port }, connectOptions);
  let secure: ReturnType<typeof socket.startTls> | undefined;
  try {
    await bounded(socket.opened);
    secure = socket.startTls({ expectedServerHostname: "callback.example" });
    await assert.rejects(bounded(secure.opened));
    await bounded(server);
  } finally { await (secure || socket).close(); listener.close(); }
});
