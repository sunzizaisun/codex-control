import { createRequire } from "node:module";
const resolve = createRequire(import.meta.url).resolve;
// Shared source lives in the separately uploadable Deno directory. Resolve
// its bare dependencies from THIS locked Workers package in Vitest as well.
export const relayAliases = [
  { find: /^ipaddr\.js$/, replacement: resolve("ipaddr.js") },
  { find: /^http-parser-js$/, replacement: resolve("http-parser-js") },
  { find: /^zod$/, replacement: resolve("zod") },
];
