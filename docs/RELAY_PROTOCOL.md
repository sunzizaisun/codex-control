# Relay protocol boundaries

## v2: normal native default

Authentication material and AES-GCM message encryption material are derived separately with scoped context. Envelopes bind room, recipient, identity, and expiry. The server stores ciphertext; it does not receive the device AES key. Do not reuse the dot key as a Codex relay administrator credential.

`RemoteRelay/src/auth-v2.mjs`, `packet.mjs`, and `Sources/CodexWatchCore/RelayCryptography.swift` are the implementation references. `RELAY_AUTH_V2` is a private operator registry, not a public configuration value. New self-hosted configurations disable legacy v1 by default. Existing installations must plan a coordinated migration rather than copy this default over their running service.

## v3: explicit device protocol

The source includes pinned owner/device grants, sender signatures, encrypted packets, bounded invitation enrollment and key delivery, staged credentials, and restart-safe journals. Store entries must not silently regenerate on read, corruption, loss of authority, or expired grants. An unknown outcome must not become a blind repeated write.

The owner export contains a public key and token hash, not private signing or encryption keys. It is input for a reviewed operator registry merge, not proof that the server accepted the owner. Normal UI/default selection must remain separate from successful local storage. Async network boundaries and platform acceptance require their own checks before deployment.

The file lease is advisory same-user process coordination, not a hostile-administrator or hardware-attestation boundary. Explicit protected Keychain selection avoids broad fallback queries; omission of a selection flag does not itself prove which store the OS searched.

## Approval and command outcomes

Commands, approval decisions, and structured answers carry original identities. Validate their request binding, nonce, content digest, expiry and expected owner. Persist the original before possible submission. Transport delivery is not execution; IPC acceptance is not an approval-resolution receipt. Two devices answering the same question must not cause duplicate submission.

## Test material

Versioned files under `RemoteRelay/tests/fixtures` contain synthetic test-only cryptographic vectors. They are not deployment credentials. Never deploy these fixtures, grant records, or keys as production identities.
