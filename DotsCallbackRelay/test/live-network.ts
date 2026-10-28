// Manual, bounded connectivity check only. No OpenAI callback, credentials or
// private messages. It does not establish deployed/real-dot success.
import { denoIO } from "../src/deno-io.ts";
import { cloudflareAddress, pinnedPost } from "../src/transport.ts";
const started = Date.now();
let observedEdge = false;
try {
  const response = await pinnedPost("https://cloudflare-dns.com/dns-query", "{}", { "Content-Type": "application/json" }, {
    ...denoIO,
    selectAddress(addresses) {
      const address = addresses.find(cloudflareAddress);
      if (!address) throw new Error("fixture-not-edge");
      observedEdge = true; return address;
    },
  });
  await response.body?.cancel();
  console.log(JSON.stringify({ check: "local-deno-public-edge-tls", connected: true,
    pinnedCloudflareAddress: observedEdge, status: response.status, milliseconds: Date.now() - started,
    realDotVerified: false, cloudDeployed: false }));
} catch {
  console.log(JSON.stringify({ check: "local-deno-public-edge-tls", connected: false,
    pinnedCloudflareAddress: observedEdge, milliseconds: Date.now() - started,
    realDotVerified: false, cloudDeployed: false })); Deno.exitCode = 1;
}
