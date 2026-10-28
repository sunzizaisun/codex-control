import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" }, miniflare: {
    bindings: { DOTS_AUTH_KEY: "local-test-dots-key", SLACK_USER_TOKEN: "xoxp-local-test" },
  } })],
  test: { include: ["test/gateway.test.ts"], setupFiles: ["./test/setup.ts"], testTimeout: 30_000 },
});
