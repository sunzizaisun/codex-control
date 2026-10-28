import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
import { relayAliases } from "./test/relay-aliases.ts";
export default defineConfig({
  resolve: { alias: relayAliases },
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.events.jsonc" }, miniflare: {
    bindings: { EVENTS_DEVICE_KEY: "fixture-device-key", EVENTS_ADMIN_KEY: "fixture-admin-key", CALLBACK_RELAY_KEY: "a".repeat(64) },
  } })],
  test: { include: ["test/oauth/**/*.test.ts"], setupFiles: ["./test/setup.ts"], testTimeout: 30_000 },
});
