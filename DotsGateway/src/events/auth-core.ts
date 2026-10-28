import { OAuthAuthorizationServer } from "@cloudflare/workers-oauth-provider";
import { z } from "zod";
export const issuer = "https://dot-inbox.example.com";
export const resource = `${issuer}/mcp`;
export const scopes = ["wearable:inbox"];
export const chatGPTClient = "https://chatgpt.com/oauth/client.json";
export const chatGPTRedirect = "https://chatgpt.com/connector_platform_oauth_redirect";
export type OwnerAuthorization = { owner: string; grant: string; client: string };
export const authorizationServer = new OAuthAuthorizationServer<DotEventsEnv>({
  issuer, resources: [resource], scopesSupported: [...scopes, "offline_access"],
  clientIdMetadataDocumentEnabled: true, accessTokenTTL: 1800,
  refreshTokenTTL: 30 * 86400, refreshTokenIdleTTL: 30 * 86400,
});
export async function grantIsActive(env: DotEventsEnv, auth: OwnerAuthorization) {
  if (auth.owner !== env.EVENTS_OWNER || auth.client !== chatGPTClient
    || !/^[^:\s]{1,128}$/.test(auth.grant)) return false;
  // Documented workers-oauth-provider 1.2.3 storage schema. A known grant must
  // use one GET, not listUserGrants() on every device poll (1,000 free LISTs/day).
  // Do not cache a positive authorization: deletions/revocations remain checked
  // on every operation, with the same KV consistency as the provider itself.
  const stored = await env.OAUTH_KV.get<unknown>(`grant:${auth.owner}:${auth.grant}`, { type: "json" });
  const parsed = z.object({ id: z.string(), userId: z.string(), clientId: z.string(),
    resource: z.string(), scope: z.array(z.string()), expiresAt: z.number().int().safe().optional(),
  }).safeParse(stored);
  if (!parsed.success) return false;
  const grant = parsed.data;
  return grant.id === auth.grant && grant.userId === auth.owner && grant.clientId === auth.client
    && grant.resource === resource && scopes.every(scope => grant.scope.includes(scope))
    && (grant.expiresAt === undefined || grant.expiresAt * 1000 > Date.now());
}
