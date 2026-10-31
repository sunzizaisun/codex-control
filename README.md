# Codex Control

把 Codex 和 dot 放到手腕上。

Codex Control 是一套 Mac、iPhone 和 Apple Watch 原生伴随应用。查看任务、跟进对话、处理审批，也可以直接与自己的 dot 聊天。

[English](README.en.md) · [下载与安装](docs/INSTALL.md) · [详细配置](docs/SETUP.md) · [使用边界](docs/LIMITATIONS.md)

## 下载与安装

[下载 Mac 应用包](https://github.com/sunzizaisun/codex-control/releases/download/v0.2.1/Codex-Control-Mac-universal.zip) · [下载源码](https://github.com/sunzizaisun/codex-control/archive/refs/heads/main.zip)

- **Mac**：解压应用包，将 `Agent Bridge.app` 拖入“应用程序”。支持 Apple Silicon 与 Intel。
- **iPhone / Apple Watch**：下载源码并解压，双击 `CodexWatch.xcodeproj`，选择自己的签名团队与设备运行。

Mac 包为临时签名，**未经苹果公证**，系统可能阻止打开；不要关闭系统安全保护。手机／手表的免费安装只需完整 Xcode，不必先装命令行工具。首次使用仍需配置自己的服务。见 [安装说明](docs/INSTALL.md)。

## 功能

- **任务随身查看**：最近任务、运行状态、计划步骤和后续消息。没有真实进度数据时，不编造完成百分比。
- **继续原来的工作**：向已有 Codex 任务发送跟进，查看返回的消息；新任务可选择模型与推理强度。
- **远程处理审批与提问**：查看请求内容，批准或拒绝；支持结构化问题、选项和文字回答。本地认证与请求有效期参与校验。
- **dot 持续聊天**：消息气泡、跨设备记录、上下文接续，以及已授权 Your dot 房间近期文字的双向记录接续。
- **查看额度**：展示账号实际提供的额度窗口和重置时间，不将窗口比例冒称为 API 金额或 token 数量。
- **原生体验**：SwiftUI、watchOS 原生输入、语言和外观设置、小组件及实时活动相关组件。
- **跨网络连接**：自托管中继连接设备，不要求处于同一局域网。dot 的云端线路不需要 Mac 常驻。

## 两条独立线路

| 用途 | 连接方式 | 是否需要 Mac 在线 |
| --- | --- | --- |
| Codex 本地任务、跟进、状态、审批 | iPhone / Watch → 加密中继 → Mac → Codex | 需要任务所在的 Mac 在线 |
| dot 消息与近期历史接续 | iPhone / Watch → Cloudflare 收件箱 → Deno 回调中继 → dot | 不需要 Mac 常驻；需要有效授权与事件订阅 |

这是独立社区项目，不隶属于 OpenAI、Apple、Cloudflare 或 Deno。软件不内置公共后端、账号凭据或个人签名资料；请连接自己的账号并部署自己的服务。

## 终端方式（可选）

需要完整 Xcode（含所需平台 SDK）、Swift 6、[XcodeGen](https://github.com/yonaskolb/XcodeGen)，云端组件使用 Node.js 24+ 和 Deno 2。

```sh
git clone https://github.com/sunzizaisun/codex-control.git
cd codex-control
node scripts/prepare-xcode.mjs
```

在 Xcode 中选择自己的开发团队及唯一 Bundle ID。先使用模拟器预览；真机需要自行配置签名、系统授权及配对。详细步骤见 [安装与配置](docs/SETUP.md)。

## 仓库结构

```text
Apps/                  Mac、iPhone、Watch、Widget 与 Live Activity
Sources/               共享协议、存储、投递和 Codex 桥接
Tests/                 Swift 单元测试及隔离原生测试宿主
RemoteRelay/           加密设备中继（Cloudflare Worker）
DotsGateway/           dot 收件箱、OAuth、历史同步和可选 Slack 适配
DotsCallbackRelay/     独立 Deno 回调中继
Resources/             平台资源与自有图标生成结果
scripts/               本地检查、隔离验收和测试工具
docs/                  配置、设计和使用边界
```

## 测试

```sh
swift test --filter CodexWatchCoreTests
swift test --filter CodexBridgeKitTests
node --test scripts/test/*.test.mjs
node scripts/scan-public-source.mjs
cd RemoteRelay && npm ci --ignore-scripts && npm test
```

dot Worker 与 Deno 的命令见 [测试说明](docs/TESTING.md)。默认自动检查不访问个人后端、不发送真实消息、不安装设备应用。

## 安全与贡献

不要提交 `.env`、`.dev.vars`、`Config/RemoteRelay.xcconfig`、聊天记录、签名证书或设备备份。报告安全问题时不要在公开 Issue 中粘贴密钥或聊天正文，见 [安全说明](SECURITY.md)。欢迎提交可复现问题和小范围、带测试的改动，见 [贡献指南](CONTRIBUTING.md)。

## 许可证

[MIT](LICENSE)。第三方依赖遵循各自许可证，见 [第三方说明](THIRD_PARTY_NOTICES.md)。商标及第三方品牌标识不在本项目的 MIT 授权范围内。
