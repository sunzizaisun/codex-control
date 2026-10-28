# dot callback relay

Deploy only this directory to your own Deno application. No organization or application is preselected.

The handler accepts authenticated callback envelopes, validates the complete public DNS address set, pins the selected IP, verifies TLS with the original hostname and refuses redirects. It does not receive OAuth bearer tokens or general chat-history access.

Required secret: `CALLBACK_RELAY_KEY`, a dedicated random 32-byte value encoded as 64 lowercase hexadecimal characters. Use the same dedicated value for the corresponding Worker binding, not a GPT login token or root Codex relay credential.

```sh
deno task check
deno task test
deno task test:native
```

The native test permits loopback networking only. Manual public-edge TLS checks are separate. Local tests do not authorize any real dot account or establish a live event subscription. See [setup](../docs/SETUP.md).
