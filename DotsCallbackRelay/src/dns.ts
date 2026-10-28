import ipaddr from "ipaddr.js";
import { z } from "zod";
import { boundedJSON } from "./body.ts";
import { EventError } from "./errors.ts";

const dnsName = z.string().max(254).refine(value => {
  const name = value.replace(/\.$/, "");
  return name.length > 0 && name.length <= 253 && name.split(".").every(label =>
    /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label));
});
const answer = z.object({ name: dnsName, type: z.number().int(),
  TTL: z.number().int().nonnegative().max(0xffffffff), data: z.string().max(254) });
const responseSchema = z.object({ Status: z.number().int(), TC: z.literal(false),
  Question: z.array(z.object({ name: dnsName, type: z.number().int() })).length(1),
  Answer: z.array(answer).max(64).optional() });
const normalize = (name: string) => name.replace(/\.$/, "").toLowerCase();
function failed(reason: NonNullable<EventError["dnsReason"]>) {
  const error = new EventError("callback_dns_failed", -32015, 503, "callback_dns");
  error.dnsReason = reason; return error;
}

// Workers' node:dns resolve4/6 flattens all Answer.data values, including CNAME
// aliases. Keep record types from the same Cloudflare resolver instead. Only
// the hostname goes to DNS; callback paths, bodies and secrets never do.
export async function resolveCallbackAddresses(hostname: string,
  request: (url: string, init: RequestInit) => Promise<Response> = fetch): Promise<string[]> {
  const name = hostname.replace(/^\[|\]$/g, "");
  if (ipaddr.isValid(name)) return [name];
  if (!dnsName.safeParse(name).success) throw failed("hostname");
  async function query(type: 1 | 28) {
    const url = new URL("https://cloudflare-dns.com/dns-query");
    url.searchParams.set("name", name); url.searchParams.set("type", String(type));
    const response = await request(url.href, { headers: { Accept: "application/dns-json" },
      // Some deployed workerd versions reject redirect:"error" before I/O.
      // manual + the non-2xx rejection below still never follows a redirect.
      redirect: "manual", signal: AbortSignal.timeout(10_000) });
    if (!response.ok) { await response.body?.cancel(); throw failed("http"); }
    let json: unknown;
    try { json = await boundedJSON(response.body, 64 * 1024); } catch { throw failed("json"); }
    const result = responseSchema.safeParse(json);
    if (!result.success) {
      const field = result.error.issues[0]?.path[0];
      throw failed(field === "Status" ? "schema_status" : field === "TC" ? "schema_truncated" : field === "Question" ? "schema_question" : "schema_answer");
    }
    const value = result.data, question = value.Question[0];
    if (normalize(question.name) !== normalize(name) || question.type !== type) throw failed("question_mismatch");
    // NXDOMAIN is an empty answer, not a reason to ignore other address types.
    if (value.Status === 3 && !value.Answer?.length) return [];
    if (value.Status !== 0) throw failed("rcode");
    const addresses: string[] = [];
    for (const record of value.Answer || []) {
      if (record.type === 5) {
        if (!dnsName.safeParse(record.data).success) throw failed("record_alias");
        continue;
      }
      if (record.type !== type) throw failed("record_type");
      if (!ipaddr.isValid(record.data)) throw failed("record_address");
      const address = ipaddr.parse(record.data);
      if (address.kind() !== (type === 1 ? "ipv4" : "ipv6") || record.data.includes("%")) throw failed("record_address");
      // Do not discard non-public records here: the caller must check the
      // complete A/AAAA set and reject mixed public/private answers.
      addresses.push(record.data);
    }
    return addresses;
  }
  try {
    const families = await Promise.all([query(1), query(28)]);
    return [...new Set(families.flat())];
  } catch (error) {
    if (error instanceof EventError) throw error;
    if (error instanceof TypeError && error.message.startsWith("Illegal invocation")) throw failed("fetch_receiver");
    if (error instanceof TypeError) throw failed("transport_type_error");
    if (error instanceof Error && ["AbortError", "TimeoutError"].includes(error.name)) throw failed("transport_abort");
    throw failed("transport");
  }
}
