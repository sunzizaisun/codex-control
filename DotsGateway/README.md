# dot inbox

`wrangler.events.jsonc` selects the authenticated MCP event inbox. `wrangler.events-preview.jsonc` is a loopback-only fixture entrypoint and refuses non-local requests. `wrangler.jsonc` selects the separate optional Slack adapter.

```sh
npm ci --ignore-scripts
npm run check
npm run check:events
npm test
npm run test:events
npx vitest run --config vitest.oauth.config.ts
```

All included test credentials are synthetic and supplied by test configuration. You do not need a personal Slack token, dot authorization, or deployed Worker for these tests.

To self-host, replace the deployment placeholders, fixed OAuth issuer and fixed authorized room, then provision your own secrets and subscription. The program must not infer another room, claim a reply from an event acknowledgement, or invent missing history. See [setup](../docs/SETUP.md) and [architecture](../docs/ARCHITECTURE.md).
