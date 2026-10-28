import { resolveCallbackAddresses } from "./dns.ts";
import type { DeliveryIO, DeliverySocket } from "./transport.ts";

// Adapt native Deno TCP/TLS to the existing, independently tested transport.
// No second DNS resolution: Deno.connect receives the validated literal IP.
function socketFor(pending: Promise<Deno.TcpConn | Deno.TlsConn>, tls: boolean): DeliverySocket {
  let connection: Deno.TcpConn | Deno.TlsConn | undefined, closing = false;
  let settleClosed!: () => void;
  const closed = new Promise<void>(resolve => { settleClosed = resolve; });
  const opened = pending.then(async conn => {
    connection = conn;
    if (closing) { try { conn.close(); } catch { /* Already closed. */ } throw new Error("closed"); }
    if (tls && "handshake" in conn) await conn.handshake();
  });
  // Handle late connections and rejections even after a deadline cancels I/O.
  void opened.catch(() => { settleClosed(); });
  async function close() {
    closing = true; settleClosed();
    if (connection) try { connection.close(); } catch { /* Already closed. */ }
  }
  return {
    opened, closed, close,
    readable: new ReadableStream<Uint8Array>({
      async pull(controller) {
        await opened;
        const bytes = new Uint8Array(16 * 1024);
        const size = await connection!.read(bytes);
        if (size === null) controller.close(); else controller.enqueue(bytes.slice(0, size));
      }, cancel: close,
    }, { highWaterMark: 0 }), // Never read plaintext before startTls consumes it.
    writable: new WritableStream<Uint8Array>({
      async write(bytes) {
        await opened;
        let at = 0;
        while (at < bytes.byteLength) {
          const size = await connection!.write(bytes.subarray(at));
          if (size <= 0) throw new Error("closed");
          at += size;
        }
      }, close, abort: close,
    }),
    startTls({ expectedServerHostname }) {
      if (tls || !connection || closing) throw new Error("invalid_tls_state");
      const tcp = connection;
      if ("handshake" in tcp) throw new Error("already_tls");
      // Original hostname supplies SNI and certificate verification. Default
      // trust roots remain enabled; never disable hostname/cert verification.
      return socketFor(Deno.startTls(tcp, { hostname: expectedServerHostname }), true);
    },
  };
}
export const denoIO: DeliveryIO = {
  resolve: resolveCallbackAddresses,
  connect(address) { return socketFor(Deno.connect({ hostname: address.hostname, port: address.port }), false); },
};
