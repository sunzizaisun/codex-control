# Architecture

## Native apps

`CodexWatchCore` defines narrow messages, account/usage presentation, encrypted transport, local outboxes, dot timelines, and pairing primitives. `CodexBridgeKit` owns the Mac-side app-server integration and durable action journal. Phone and Watch controllers project verified snapshots into SwiftUI.

The bridge deduplicates by original message identity and preserves uncertain outcomes. A relay acknowledgement means transport acceptance, not that a Codex command executed or an approval took effect. Lost authority, expired requests, malformed responses, and missing receipts must not become optimistic success.

Codex integration uses app-server where available. The desktop task-follower adapter is version-sensitive and is not a public, stable API. It checks exact task identity; an incompatible interface must fail closed, not send to an arbitrary visible chat.

## Cloud components

`RemoteRelay` stores authenticated encrypted envelopes. Its v2 protocol separates server authentication from device encryption. New v3 source primitives add device identity, signed envelopes, pinned grants, and explicit enrollment. The normal application default remains v2; v3 is not selected just because key material exists locally. See [protocol boundaries](RELAY_PROTOCOL.md).

`DotsGateway/src/events` implements the separately authorized dot inbox. It keeps original IDs, delivery/read/reply stages, bounded history imports, and idempotent tool replies. `DotsCallbackRelay` is independently deployable: it validates authenticated callback envelopes, checks public DNS, pins the destination, verifies TLS using the hostname, and refuses redirects.

The event inbox never acquires terminal, filesystem, or Codex approval authority. Its cloud route does not call the Mac bridge. The optional Slack adapter in `DotsGateway/src/index.ts` is separate and must not be confused with the event route.

## Records and privacy

Official Your dot synchronization is an explicitly authorized copy of recent text, not universal access to account history. Companion-origin mirrors in the official room are assistant posts with original IDs, not forged native user messages. Local pending text, relay receipts, returned replies, and official-history imports have independent lifecycles.

No deployment credentials, personal logs, user conversations, old application packages, or provisioning profiles are included in this repository.
