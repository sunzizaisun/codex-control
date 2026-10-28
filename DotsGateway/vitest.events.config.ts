import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";
import { relayAliases } from "./test/relay-aliases.ts";

export default defineConfig({
  resolve: { alias: relayAliases },
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.events-preview.jsonc" }, miniflare: {
    bindings: { EVENTS_DEVICE_KEY: "fixture-device-key", EVENTS_MCP_KEY: "fixture-mcp-key" },
  } })],
  test: { include: ["test/events/**/*.test.ts"], setupFiles: ["./test/setup.ts"], testTimeout: 30_000 },
});
