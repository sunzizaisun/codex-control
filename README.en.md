# Codex Control

A native Mac, iPhone, and Apple Watch companion for Codex and dot.

[简体中文](README.md) · [Download & install](docs/INSTALL.md) · [Configuration](docs/SETUP.md) · [Limitations](docs/LIMITATIONS.md)

## Download & install

[Mac app ZIP](https://github.com/sunzizaisun/codex-control/releases/download/v0.2.1/Codex-Control-Mac-universal.zip) · [Source ZIP](https://github.com/sunzizaisun/codex-control/archive/refs/heads/main.zip)

- **Mac:** extract the app ZIP and move `Agent Bridge.app` to Applications. Supports Apple Silicon and Intel.
- **iPhone / Apple Watch:** extract the source ZIP, double-click `Setup.command`, then choose your own signing team and device in Xcode.

The Mac package is ad-hoc signed, **not Apple-notarized**, and may be blocked by macOS. Do not disable system security. Free iPhone/Watch installation requires full Xcode, Node.js 24+, and XcodeGen. Configure your own backend before connecting. See [installation details](docs/INSTALL.md).

Follow tasks from your wrist, continue conversations, review approvals, answer structured questions, and chat with your dot across devices. The interface uses SwiftUI, native watchOS input, language and appearance preferences, and platform widgets/activity components.

## What it does

- Task lists, real running states, plan steps, and follow-up messages.
- New Codex tasks with model and reasoning selection.
- Scoped approval decisions and structured answers, with local authentication checks.
- Persistent dot conversations, cross-device history, and bounded authorized Your dot text synchronization.
- Actual account usage windows and reset information when supplied by the backend.
- Encrypted, self-hosted device relay across different networks.

Local Codex execution still needs its host Mac online. The separate dot route runs through Cloudflare and Deno and does not require a running Mac bridge. It requires your own valid authorization and event subscription. Delivery, read, reply, and official-history synchronization are distinct states.

This is an independent community project, not an official OpenAI or Apple product. No hosted public backend, account credentials, or signing identity is bundled.

## Build

Install full Xcode with the desired platform SDKs and XcodeGen. Swift 6 is required; cloud components use Node.js 24+ and Deno 2.

```sh
git clone https://github.com/sunzizaisun/codex-control.git
cd codex-control
node scripts/prepare-xcode.mjs
```

Choose your own signing team and unique Bundle IDs. Configure your own endpoints and secrets using [Setup](docs/SETUP.md). Run the isolated checks in [Testing](docs/TESTING.md) before connecting accounts or installing on physical devices.

## Components

`Apps` contains the native apps and extensions. `Sources` and `Tests` contain the shared protocol, storage, bridge, and regression tests. `RemoteRelay` provides the encrypted device relay. `DotsGateway` provides the dot inbox, OAuth, history synchronization, and optional Slack adapter. `DotsCallbackRelay` is the separately deployable Deno callback relay.

## License and security

[MIT](LICENSE), with third-party notices preserved in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Third-party trademarks and brand assets are not licensed by this project. See [SECURITY.md](SECURITY.md) before reporting sensitive issues and [CONTRIBUTING.md](CONTRIBUTING.md) for contributions.
