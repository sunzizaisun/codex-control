# Security

Do not post API keys, OAuth tokens, relay secrets, private keys, pairing capabilities, device identifiers, or chat transcripts in public issues. Use GitHub's private vulnerability reporting feature when available; otherwise ask the maintainer for a private reporting channel without including the sensitive payload.

This repository contains source and synthetic test vectors, not a public hosted service. Each operator is responsible for their own endpoints, identity registry, signing, authorization and secret storage. Do not deploy fixture keys or copy another operator's registry.

## Local checks

Run `node scripts/scan-public-source.mjs` before committing. It checks prohibited file classes and common credential patterns without printing matched values. This is defense in depth, not a guarantee that every possible secret can be recognized. Review the exact staged diff, including generated files and commit metadata.

If a credential is exposed, revoke/rotate it at its issuer first. Deleting a file or rewriting Git history cannot make a previously public secret safe again. Do not weaken TLS, authentication, local user-presence checks or request binding to make a test pass.

## Trust boundaries

The device relay, dot inbox, Mac action executor and platform authentication have separate authority. A delivered event is not a model read receipt; a stored reply is not an official-history sync; an accepted approval message is not proof that the original task resumed. Preserve these distinctions when making changes.
