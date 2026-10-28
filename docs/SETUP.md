# 安装与自托管

## 1. 原生应用

安装完整 Xcode、需要的平台 SDK 和 XcodeGen。基础目标为 macOS 13、iOS 17、watchOS 10；Live Activity 扩展目标为 iOS 18。新系统使用可用的玻璃材质，旧系统采用系统回退样式。

在仓库根目录执行：

```sh
node scripts/bootstrap.mjs
node scripts/generate-icons.mjs
xcodegen generate
open CodexWatch.xcodeproj
```

`bootstrap` 只创建缺失的空配置，不覆盖已有配置，不连接云端、不读取 Keychain。图标脚本生成本项目自己的图形，不使用 OpenAI 图标。Xcode 工程由 `project.yml` 生成，不分发个人工程或签名资料。

在 Xcode 中为每个应用及扩展选择自己的开发团队，并使用可注册的唯一 Bundle ID。应用与扩展的 Bundle ID、关联的 companion ID 和受保护存储组需要一致；不要仅修改其中一个。

填入本地忽略文件 `Config/RemoteRelay.xcconfig`：

```xcconfig
SLASH = /
CODEX_RELAY_URL = https:/$(SLASH)/YOUR-RELAY-HOST
CODEX_RELAY_ROOM = YOUR-OWN-ROOM
CODEX_RELAY_SECRET = YOUR-OWN-RANDOM-SECRET
CODEX_DOTS_URL = https:/$(SLASH)/YOUR-DOT-INBOX-HOST
CODEX_BROWSER_GATEWAY_ENABLED = NO
```

示例不是有效凭据。Mac 的 Codex 程序和登录账号由本机用户自行设置。首次使用可能需要辅助功能、本地网络或相机等系统权限；只授权自己构建且确认来源的程序。

## 2. Codex 设备中继

`RemoteRelay` 是独立 Cloudflare Worker。先在该目录安装锁定依赖并跑离线测试：

```sh
cd RemoteRelay
npm ci --ignore-scripts
npm test
```

在自己的 Cloudflare 账号创建 Worker 和绑定。`wrangler.toml` 保留类名及迁移结构，但不包含任何个人账号 ID 或中继密钥。创建自己的 `RELAY_AUTH_V2` 私有登记记录，使用 `scripts/lib/relay-v2-credentials.mjs` 的既有派生格式；只上传服务器鉴权记录，不上传设备 AES 密钥。常规原生默认使用 v2，不能拿 v3-only 的房间直接替换它。

本仓库不会替你部署，也没有跨账号通用的房间或公共服务器。配置与迁移前阅读 [协议说明](RELAY_PROTOCOL.md)。

## 3. dot 事件线路

事件版入口为 `DotsGateway/src/events/production.ts`，配置为 `DotsGateway/wrangler.events.jsonc`。`wrangler.jsonc` 是另一条可选 Slack 线路，不要误用。

部署前必须设置自己的：

1. Worker 名称、OAuth KV ID、回调中继 HTTPS 地址。
2. `src/events/auth-core.ts` 中的固定 HTTPS `issuer`；它必须与自己的 Worker/域名一致，不能让请求者自由指定。
3. `src/events/history.ts` 中唯一授权的 Your dot 房间 ID；源码中的全零值只是占位符，不代表任何真实房间。不要放宽到任意房间。
4. 设备访问密钥 `EVENTS_DEVICE_KEY`、仅管理员使用的 `EVENTS_ADMIN_KEY`，以及与 Deno 共用的专用 `CALLBACK_RELAY_KEY`。密钥各司其职，不混用。
5. 在自己的 ChatGPT 账号中授权 MCP 连接，并创建相应事件订阅/任务。普通工具可用不等于事件已订阅；需要明确处理新消息和回填控制请求，并用 `reply_to_wearable_message` 返回真实回复。

原生客户端当前通过 `DotsConfiguration.derivedKey` 按 `mcp-events` 通道派生访问键；服务器的 `EVENTS_DEVICE_KEY` 必须与该客户端配置匹配。不要把管理员密钥写入原生配置。

将 **仅 `DotsCallbackRelay` 目录** 部署到自己的 Deno 应用。其 `deno.json` 不包含任何人的组织或应用绑定。设置独立 `CALLBACK_RELAY_KEY`，必须是 32 字节随机值的 64 位小写十六进制编码，与 Worker 中的该项一致。它不是 GPT 登录令牌。Deno 启动权限及本地测试见该目录的 `deno.json`。

配置私有值请使用服务提供方的 secret store。Cloudflare 的 [Secrets 文档](https://developers.cloudflare.com/workers/configuration/secrets/)说明了本地 `.dev.vars`/`.env` 与线上 secrets 的区别；不要把私有值写入 `vars` 后提交。发布命令会改变自己的线上服务，应在自己的账号中核对目标后执行。

## 4. 首次验证

先运行 [离线检查](TESTING.md)，再以自己的独立测试房间确认消息原文、真实回复、第二轮上下文、跨端历史与重复 ID。不要将一个健康检查、模拟器假数据或 HTTP 200 当作完整收发通过。

涉及审批时必须核对原 Codex 任务实际继续执行；涉及 reset 时核对账号真实消费结果。不要用可能产生费用、删除文件或修改生产资源的操作做随手测试。
