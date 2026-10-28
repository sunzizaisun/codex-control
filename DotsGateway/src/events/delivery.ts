import { connect } from "cloudflare:sockets";
import { EventError, signedPost, verifyCallback, type Subscription } from "./protocol";
import { resolveCallbackAddresses } from "./dns";
import { cloudflareAddress, pinnedPost as sharedPost, type DeliveryIO } from "../../../DotsCallbackRelay/src/transport";
import { relayPost, type RelayConfiguration } from "../../../DotsCallbackRelay/src/client";
export type { RelayConfiguration } from "../../../DotsCallbackRelay/src/client";
export { callbackURL, cloudflareAddress, publicAddress, type DeliveryIO } from "../../../DotsCallbackRelay/src/transport";
const platform: DeliveryIO = { resolve: resolveCallbackAddresses, connect };
// Only this adapter excludes the edge ranges that Workers TCP cannot reach.
export async function pinnedPost(raw: string, body: string, headers: Record<string, string>, io = platform): Promise<Response> {
  return sharedPost(raw, body, headers, { ...io, selectAddress(addresses) {
    const address = addresses.find(value => !cloudflareAddress(value));
    if (address) return address;
    const error = new EventError("callback_transport_unsupported", -32015, 503, "callback_tcp");
    error.destinationNetwork = "cloudflare_edge"; throw error;
  } });
}
export const signedLivePost = (sub: Subscription, id: string, payload: unknown, relay?: RelayConfiguration) => signedPost(sub, id, payload,
  relay ? (url, body, headers) => relayPost(relay, url, body, headers) : pinnedPost);
export const verifyLiveCallback = (sub: Subscription, relay?: RelayConfiguration) => verifyCallback(sub,
  (subscription, id, payload) => signedLivePost(subscription, id, payload, relay));
