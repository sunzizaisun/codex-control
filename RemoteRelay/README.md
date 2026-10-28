# Encrypted device relay

Cloudflare Worker for encrypted Codex device snapshots, commands and scoped pairing. It is not the dot chat inbox.

```sh
npm ci --ignore-scripts
npm test
```

Set up your own Worker and private `RELAY_AUTH_V2` operator registry. Keep device encryption material off the server. Legacy v1 is disabled in the public template; do not copy this template over an existing deployment without a coordinated client migration. The native default is v2; v3 source primitives do not automatically migrate clients.

See [setup](../docs/SETUP.md), [protocol boundaries](../docs/RELAY_PROTOCOL.md), and [security](../SECURITY.md). `tests/fixtures` contains synthetic test-only material, never production identities.
