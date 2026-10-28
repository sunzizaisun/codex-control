// Shared with Cloudflare. Never include URLs, IPs, credentials, message
// bodies or raw exceptions in categorized operational metadata.
export class EventError extends Error {
  addressKinds?: string[];
  destinationNetwork?: "cloudflare_edge";
  dnsReason?: "hostname" | "transport" | "transport_type_error" | "transport_abort" | "fetch_receiver" | "http" | "json" | "schema_status" | "schema_truncated" | "schema_question" | "schema_answer" | "question_mismatch" | "rcode" | "record_type" | "record_address" | "record_alias";
  constructor(public code: string, public rpcCode = -32602, public status = 400,
    public phase?: "callback_url" | "callback_dns" | "callback_dns_empty" | "callback_address_blocked" | "callback_tcp" | "callback_tls" | "callback_http" | "callback_relay") { super(code); }
}
