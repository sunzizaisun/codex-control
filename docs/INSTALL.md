# 下载与安装 / Download and install

## 最短路径

**Mac**：[下载应用包](https://github.com/sunzizaisun/codex-control/releases/download/v0.2.1/Codex-Control-Mac-universal.zip)，解压，将 `Agent Bridge.app` 拖入“应用程序”。下载包无需 Xcode，支持 Apple Silicon 和 Intel；请先阅读下面的签名限制。

**iPhone / Apple Watch（免费方式）**：

1. [下载源码 ZIP](https://github.com/sunzizaisun/codex-control/archive/refs/heads/main.zip)，解压。
2. 双击 `Setup.command`，自动生成并打开 Xcode 工程。
3. 选择 `CodexRelay`，在 Signing & Capabilities 中选择自己的 Team，再选择自己的设备运行。该 iPhone 应用包含 Watch 伴随应用。需为各目标设置自己的唯一 Bundle ID，并保持 companion ID 一致，详见 [配置说明](SETUP.md)。

如需自行构建 Mac 版，双击源码中的 `Build Mac.command`，完成后自动打开输出文件夹。脚本不会安装、替换旧版或启动应用。

源码构建需要 Mac、完整 Xcode、Node.js 24+、XcodeGen 2.45.4+。脚本会检查依赖；不会自动安装工具、运行 `sudo`、改动全局 Xcode 路径或关闭系统安全保护。如果提示缺少 XcodeGen，可在已安装 Homebrew 的终端执行 `brew install xcodegen`。

如果系统不允许双击脚本，可在解压后的目录用终端执行 `node scripts/prepare-xcode.mjs` 或 `node scripts/build-mac.mjs`，不需要修改安全设置。

## 下载后直接安装的边界

| 平台 | 当前方式 | 无需编译的分发方式 |
| --- | --- | --- |
| Mac | 下载通用 ZIP，或自行一键构建 `.app` | 无系统安全警告的公开分发需要 Developer ID 签名及苹果公证 |
| iPhone / Watch | 用自己的 Xcode 团队签名安装 | 需要发布者完成 TestFlight / App Store 分发；不能直接用通用 IPA 替代 |

**Mac 下载包只有临时签名，未经苹果公证**，不等于受信任发行版，系统可能阻止打开。不要通过关闭 Gatekeeper 来解决安装问题。iPhone / Watch 自签安装会受到苹果账号及签名有效期限制；免费方式可能需要定期重新签名安装。

应用安装与后端配置是两件事。软件不包含公共服务或个人密钥；首次连接仍需自己的中继配置及配对。dot 需单独授权并启用事件订阅。Mac 构建脚本始终用空配置打包，不会把本机的私有配置复制进去。

## English

Download the [Mac app ZIP](https://github.com/sunzizaisun/codex-control/releases/download/v0.2.1/Codex-Control-Mac-universal.zip) or the [source ZIP](https://github.com/sunzizaisun/codex-control/archive/refs/heads/main.zip).

- **Mac:** extract the app ZIP and move `Agent Bridge.app` to Applications. Xcode is not required for this download. To build it yourself, double-click `Build Mac.command` in the source download; outputs go into `dist`. Nothing is installed, replaced or launched automatically.
- **iPhone / Watch:** double-click `Setup.command`. In the generated Xcode project select `CodexRelay`, choose your own signing team and device, and use unique, consistent bundle/companion identifiers. See [Setup](SETUP.md).

Source-build requirements: macOS, full Xcode, Node.js 24+, XcodeGen 2.45.4+. The helpers do not install dependencies or change global settings. Terminal alternatives are `node scripts/prepare-xcode.mjs` and `node scripts/build-mac.mjs`; add `--no-open` for headless use.

The Mac package is ad-hoc signed, **not Apple-notarized**, and has blank backend configuration. macOS may block it. A frictionless public Mac download needs Developer ID signing and notarization. iPhone and Watch link-based installation requires an authorized distribution method such as TestFlight; the free Xcode route may need periodic re-signing. Never disable system security to install this project.

Installer signing references: [Apple distribution overview](https://help.apple.com/xcode/mac/current/en.lproj/devac02c5ab8.html), [macOS notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
