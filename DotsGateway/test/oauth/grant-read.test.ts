// Isolated storage fixtures, never a live token or real account grant.
import { env } from "cloudflare:workers";
import { reset } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { chatGPTClient, grantIsActive, resource } from "../../src/events/auth-core";

afterEach(async () => { vi.restoreAllMocks(); await reset(); });
describe("known-grant authorization without KV LIST", () => {
  const auth = { owner: "wearable-owner", grant: "fixture-grant", client: chatGPTClient };
  const stored = () => ({ id: auth.grant, userId: auth.owner, clientId: auth.client,
    resource, scope: ["wearable:inbox"], expiresAt: Math.floor(Date.now() / 1000) + 3600 });
  const key = `grant:${auth.owner}:${auth.grant}`;
  it("still works when LIST quota is exhausted and checks revocation on the next call", async () => {
    const list = vi.spyOn(env.OAUTH_KV, "list").mockRejectedValue(new Error("fixture LIST quota exhausted"));
    await env.OAUTH_KV.put(key, JSON.stringify(stored()));
    for (let i = 0; i < 5; i++) expect(await grantIsActive(env, auth)).toBe(true);
    expect(list).not.toHaveBeenCalled();
    await env.OAUTH_KV.delete(key);
    expect(await grantIsActive(env, auth)).toBe(false);
    expect(list).not.toHaveBeenCalled();
  });
  it("fails closed for missing, expired, malformed or incorrectly bound grants", async () => {
    const variants = [null, {}, { ...stored(), id: "other" }, { ...stored(), userId: "other" },
      { ...stored(), clientId: "other" }, { ...stored(), resource: "https://other.invalid/mcp" },
      { ...stored(), scope: [] }, { ...stored(), scope: "wearable:inbox" },
      { ...stored(), expiresAt: Math.floor(Date.now() / 1000) - 1 }, { ...stored(), expiresAt: "future" }];
    for (const value of variants) {
      await env.OAUTH_KV.put(key, JSON.stringify(value));
      expect(await grantIsActive(env, auth)).toBe(false);
    }
    for (const wrong of [{ ...auth, owner: "other" }, { ...auth, client: "other" }, { ...auth, grant: "x:y" }]) {
      expect(await grantIsActive(env, wrong)).toBe(false);
    }
  });
});
