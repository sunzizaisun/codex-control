import { describe, expect, it, vi } from "vitest";
import { resolveCallbackAddresses } from "../../src/events/dns";
import { pinnedPost, type DeliveryIO } from "../../src/events/delivery";
import { http } from "msw";
import { network } from "../network";

const record = (type: number, data: string) => ({ name: "alias.example.", type, TTL: 30, data });
function response(type: number, records: unknown[] = []) {
  return { Status: 0, TC: false, Question: [{ name: "callback.example.", type }], Answer: records };
}
function fixture(change?: (type: number, body: ReturnType<typeof response>) => unknown) {
  return vi.fn(async (raw: string, _init: RequestInit) => {
    const type = Number(new URL(raw).searchParams.get("type"));
    const body = response(type, [record(5, "alias.example."), record(type, type === 1 ? "8.8.8.8" : "2606:4700:4700::1111")]);
    return Response.json(change ? change(type, body) : body);
  });
}
describe("typed callback DNS (fixture responses, no real dot)", () => {
  it("uses the real Workers global fetch invocation path with a mocked DNS response", async () => {
    network.use(http.get("https://cloudflare-dns.com/dns-query", ({ request }) => {
      expect(request.redirect).toBe("manual");
      const type = Number(new URL(request.url).searchParams.get("type"));
      return Response.json(response(type, [record(type, type === 1 ? "8.8.8.8" : "2606:4700:4700::1111")]));
    }));
    // Exercise native Request option validation, which an injected JS
    // transport alone did not cover (redirect:"error" failed at this layer).
    expect(await resolveCallbackAddresses("callback.example")).toEqual(["8.8.8.8", "2606:4700:4700::1111"]);
  });
  it("ignores valid CNAME records, retains both IP families and uses fixed credential-free DoH", async () => {
    const request = fixture();
    expect(await resolveCallbackAddresses("callback.example", request)).toEqual(["8.8.8.8", "2606:4700:4700::1111"]);
    expect(request).toHaveBeenCalledTimes(2);
    for (const [raw, init] of request.mock.calls) {
      const url = new URL(raw);
      expect(url.origin + url.pathname).toBe("https://cloudflare-dns.com/dns-query");
      expect(url.searchParams.get("name")).toBe("callback.example");
      expect([...url.searchParams.keys()]).toEqual(["name", "type"]);
      expect(init.redirect).toBe("manual");
      expect(init.headers).toEqual({ Accept: "application/dns-json" });
      expect(init.signal).toBeInstanceOf(AbortSignal);
    }
  });
  it("does not query DNS for literal addresses", async () => {
    const request = fixture();
    expect(await resolveCallbackAddresses("[2606:4700:4700::1111]", request)).toEqual(["2606:4700:4700::1111"]);
    expect(request).not.toHaveBeenCalled();
  });
  it("retains private addresses so mixed public/private records remain blocked", async () => {
    const request = fixture((type, body) => type === 1 ? { ...body, Answer: [...body.Answer, record(1, "10.0.0.1")] } : body);
    const connect = vi.fn();
    const io: DeliveryIO = { resolve: name => resolveCallbackAddresses(name, request), connect };
    await expect(pinnedPost("https://callback.example/events", "{}", {}, io)).rejects.toMatchObject({ code: "callback_blocked", phase: "callback_address_blocked" });
    expect(connect).not.toHaveBeenCalled();
  });
  it("accepts an absent family and de-duplicates identical addresses", async () => {
    const request = fixture((type, body) => ({ ...body, Answer: type === 1 ? [record(1, "8.8.8.8"), record(1, "8.8.8.8")] : [] }));
    expect(await resolveCallbackAddresses("callback.example", request)).toEqual(["8.8.8.8"]);
  });
  it("returns no addresses for NXDOMAIN without answers", async () => {
    const request = fixture((_type, body) => ({ ...body, Status: 3, Answer: undefined }));
    expect(await resolveCallbackAddresses("callback.example", request)).toEqual([]);
  });
  it.each([
    ["truncated", (_t: number, b: ReturnType<typeof response>) => ({ ...b, TC: true })],
    ["DNS error", (_t: number, b: ReturnType<typeof response>) => ({ ...b, Status: 2 })],
    ["wrong question", (_t: number, b: ReturnType<typeof response>) => ({ ...b, Question: [{ name: "other.example.", type: 1 }] })],
    ["missing question", (_t: number, b: ReturnType<typeof response>) => ({ ...b, Question: [] })],
    ["malformed IP", (t: number, b: ReturnType<typeof response>) => ({ ...b, Answer: [record(t, "not-an-address")] })],
    ["wrong IP family", (t: number, b: ReturnType<typeof response>) => ({ ...b, Answer: [record(t, t === 1 ? "::1" : "8.8.8.8")] })],
    ["malformed CNAME", (_t: number, b: ReturnType<typeof response>) => ({ ...b, Answer: [record(5, "https://bad.example")] })],
    ["unexpected record", (_t: number, b: ReturnType<typeof response>) => ({ ...b, Answer: [record(16, "ignored? no")] })],
    ["too many records", (t: number, b: ReturnType<typeof response>) => ({ ...b, Answer: Array.from({ length: 65 }, () => record(t, "8.8.8.8")) })],
    ["NXDOMAIN with address", (_t: number, b: ReturnType<typeof response>) => ({ ...b, Status: 3 })],
  ] as const)("fails closed on %s, without exposing response detail", async (_label, change) => {
    await expect(resolveCallbackAddresses("callback.example", fixture(change))).rejects.toMatchObject({ code: "callback_dns_failed", message: "callback_dns_failed", phase: "callback_dns" });
  });
  it("fails closed if either family has a transport error", async () => {
    const good = fixture();
    const request = async (raw: string, init: RequestInit) => {
      if (new URL(raw).searchParams.get("type") === "28") throw new Error("fixture-sensitive-error");
      return good(raw, init);
    };
    await expect(resolveCallbackAddresses("callback.example", request)).rejects.toMatchObject({ code: "callback_dns_failed", message: "callback_dns_failed", dnsReason: "transport" });
  });
  it("does not accept HTTP redirects/errors", async () => {
    const request = vi.fn(async () => new Response(null, { status: 302, headers: { Location: "http://127.0.0.1" } }));
    await expect(resolveCallbackAddresses("callback.example", request)).rejects.toMatchObject({ code: "callback_dns_failed", dnsReason: "http" });
  });
  it("bounds DNS JSON bytes", async () => {
    const request = vi.fn(async () => new Response(" ".repeat(65537), { status: 200 }));
    await expect(resolveCallbackAddresses("callback.example", request)).rejects.toMatchObject({ code: "callback_dns_failed", dnsReason: "json" });
  });
});
