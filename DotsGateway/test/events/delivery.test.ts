import { describe, expect, it, vi } from "vitest";
import { callbackURL, cloudflareAddress, pinnedPost, publicAddress, type DeliveryIO } from "../../src/events/delivery";

function fixture(response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}", addresses = ["8.8.8.8"]) {
  const written: Uint8Array[] = [];
  const close = vi.fn(async () => {}), tls = vi.fn();
  const socket: Socket = {
    readable: new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode(response)); c.close(); } }),
    writable: new WritableStream({ write(chunk) { written.push(new Uint8Array(chunk)); } }),
    opened: Promise.resolve({ remoteAddress: "8.8.8.8:443", localAddress: "test" }), closed: Promise.resolve(), close,
    upgraded: true, secureTransport: "on",
    startTls(options) { tls(options); return socket; },
  };
  const connect = vi.fn(() => socket), resolve = vi.fn(async () => addresses);
  const io: DeliveryIO = { connect, resolve };
  return { io, socket, written, close, connect, resolve, tls };
}
describe("IP-pinned callback transport (mock sockets, no real dot)", () => {
  it.each(["127.0.0.1", "10.0.0.1", "169.254.169.254", "192.168.0.1", "100.64.1.1", "::1", "fc00::1", "fe80::1", "::ffff:8.8.8.8", "2001:db8::1", "invalid"])("blocks non-public address %s", address => {
    expect(publicAddress(address)).toBe(false);
  });
  it.each(["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111"])("accepts public address %s", address => expect(publicAddress(address)).toBe(true));
  it.each(["http://callback.example/x", "https://user:pass@callback.example/x", "https://callback.example:8443/x", "https://localhost/x", "https://callback.local/x", "https://callback.invalid/x", "https://callback.example/x#secret"])("blocks invalid callback %s", raw => {
    expect(() => callbackURL(raw)).toThrow();
  });
  it("connects to the validated IP, verifies TLS hostname, preserves Unicode bytes", async () => {
    const f = fixture(), body = JSON.stringify({ text: "松果-742，🙂" });
    expect((await pinnedPost("https://callback.example/events?one=1", body, { "Content-Type": "application/json" }, f.io)).status).toBe(200);
    expect(f.resolve).toHaveBeenCalledWith("callback.example");
    expect(f.connect).toHaveBeenCalledWith({ hostname: "8.8.8.8", port: 443 }, { secureTransport: "starttls", allowHalfOpen: false });
    expect(f.tls).toHaveBeenCalledWith({ expectedServerHostname: "callback.example" });
    const headers = new TextDecoder().decode(f.written[0]);
    expect(headers).toContain("POST /events?one=1 HTTP/1.1\r\n");
    expect(headers).toContain(`Content-Length: ${new TextEncoder().encode(body).byteLength}\r\n`);
    expect(headers).toContain("Host: callback.example\r\n");
    expect(new TextDecoder().decode(f.written[1])).toBe(body); expect(f.close).toHaveBeenCalledOnce();
  });
  it("rejects mixed public/private DNS answers before connecting", async () => {
    const f = fixture(undefined, ["8.8.8.8", "10.0.0.1"]);
    await expect(pinnedPost("https://callback.example/x", "{}", {}, f.io)).rejects.toMatchObject({ code: "callback_blocked", phase: "callback_address_blocked", addressKinds: ["unicast", "private"] });
    expect(f.connect).not.toHaveBeenCalled();
  });
  it("rejects absent DNS answers before connecting", async () => {
    const f = fixture(undefined, []);
    await expect(pinnedPost("https://callback.example/x", "{}", {}, f.io)).rejects.toMatchObject({ code: "callback_blocked", phase: "callback_dns_empty" });
    expect(f.connect).not.toHaveBeenCalled();
  });
  it("reports a known Workers platform restriction without trying an unsafe fetch fallback", async () => {
    const f = fixture(undefined, ["104.16.0.1", "2606:4700:4700::1111"]);
    await expect(pinnedPost("https://callback.example/x", "{}", {}, f.io)).rejects.toMatchObject({ code: "callback_transport_unsupported", phase: "callback_tcp", destinationNetwork: "cloudflare_edge" });
    expect(f.connect).not.toHaveBeenCalled();
  });
  it("uses only an alternative public address from the same DNS response", async () => {
    const f = fixture(undefined, ["104.16.0.1", "8.8.8.8"]);
    expect((await pinnedPost("https://callback.example/x", "{}", {}, f.io)).status).toBe(200);
    expect(f.resolve).toHaveBeenCalledOnce();
    expect(f.connect).toHaveBeenCalledWith({ hostname: "8.8.8.8", port: 443 }, { secureTransport: "starttls", allowHalfOpen: false });
    expect(f.tls).toHaveBeenCalledWith({ expectedServerHostname: "callback.example" });
  });
  it("does not allow a private alternative even when the first answer is Cloudflare", async () => {
    const f = fixture(undefined, ["104.16.0.1", "10.0.0.1"]);
    await expect(pinnedPost("https://callback.example/x", "{}", {}, f.io)).rejects.toMatchObject({ code: "callback_blocked", phase: "callback_address_blocked" });
    expect(f.connect).not.toHaveBeenCalled();
  });
  it.each([["104.16.0.1", true], ["172.64.1.1", true], ["2606:4700:4700::1111", true], ["8.8.8.8", false], ["10.0.0.1", false], ["invalid", false]])("classifies the public Cloudflare proxy range %s", (address, expected) => {
    expect(cloudflareAddress(String(address))).toBe(expected);
  });
  it("fails closed on TLS failure without writing or falling back to fetch", async () => {
    const f = fixture(); f.socket.startTls = () => { throw new Error("certificate mismatch"); };
    await expect(pinnedPost("https://callback.example/x", "{}", {}, f.io)).rejects.toMatchObject({ code: "callback_connection_failed", phase: "callback_tls" });
    expect(f.written).toHaveLength(0); expect(f.close).toHaveBeenCalledOnce();
  });
  it("categorizes synchronous socket errors without exposing platform messages", async () => {
    const f = fixture(); f.io.connect = () => { throw new Error("fixture-private-transport-detail"); };
    await expect(pinnedPost("https://callback.example/x", "{}", {}, f.io)).rejects.toMatchObject({ code: "callback_connection_failed", phase: "callback_tcp", message: "callback_connection_failed" });
    expect(f.written).toHaveLength(0);
  });
  it("parses a bounded chunked challenge response", async () => {
    const f = fixture("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n{}\r\n0\r\n\r\n");
    expect(await (await pinnedPost("https://callback.example/x", "{}", {}, f.io)).text()).toBe("{}");
  });
  it("returns redirects without following them", async () => {
    const f = fixture("HTTP/1.1 302 Found\r\nLocation: http://169.254.169.254/\r\nContent-Length: 0\r\n\r\n");
    expect((await pinnedPost("https://callback.example/x", "{}", {}, f.io)).status).toBe(302);
    expect(f.connect).toHaveBeenCalledOnce();
  });
  it("bounds callback response bodies", async () => {
    const f = fixture(`HTTP/1.1 200 OK\r\nContent-Length: 8193\r\n\r\n${"x".repeat(8193)}`);
    await expect(pinnedPost("https://callback.example/x", "{}", {}, f.io)).rejects.toThrow();
  });
  it("bounds callback headers", async () => {
    const f = fixture(`HTTP/1.1 200 OK\r\nLarge: ${"x".repeat(17000)}\r\nContent-Length: 0\r\n\r\n`);
    await expect(pinnedPost("https://callback.example/x", "{}", {}, f.io)).rejects.toThrow();
  });
  it("does not accept truncated response data", async () => {
    const f = fixture("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{");
    await expect(pinnedPost("https://callback.example/x", "{}", {}, f.io)).rejects.toThrow();
  });
  it("does not send malformed headers", async () => {
    const f = fixture();
    await expect(pinnedPost("https://callback.example/x", "{}", { bad: "a\r\nInjected: 1" }, f.io)).rejects.toThrow();
    expect(f.written).toHaveLength(0);
  });
});
