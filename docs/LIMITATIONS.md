# 使用边界 / Operating boundaries

- **电脑离线**：dot 的原云端线路不依赖 Mac 常驻；执行 Mac 上的 Codex 项目仍需要该 Mac 在线。它不能在电脑关机时替电脑执行本地工作。
- **dot 延迟**：云端接收、事件投递、dot 读取、回复和官方记录同步是不同阶段。上游任务调度可能带来明显等待，不保证即时回复或固定延迟。
- **历史范围**：Your dot 回填限于明确授权房间最近最多 30 条文字。它不是完整账号历史备份，不读取其他对话、邮件、附件或文件。
- **后台提醒**：系统可能挂起 iPhone/Watch 应用。后台刷新、Widget、Smart Stack 和 Live Activity 不构成实时送达保证；本仓库不内置 APNs 服务或签名能力。
- **远程认证**：iPhone 采用系统允许的本地认证路径；Watch 受佩戴、解锁及系统能力限制。Mac 附近的系统手表双击确认不能当作跨互联网的远程认证。
- **审批结果**：只有原任务的确认才能证明决定已生效。过期、重复、内容不匹配或结果不明确时，不能显示成批准成功。
- **兼容性**：桌面 task-follower 适配不是稳定公开 API。Codex/ChatGPT 或系统更新后，应先验证兼容性；不兼容时停止发送。
- **额度显示**：窗口剩余百分比不是 API 美元余额、精确 token 数或剩余消息条数。字段缺失时不编造数字。
- **鉴权协议**：常规原生路径使用 v2；v3 协议代码和隔离测试不等于正式客户端已迁移。不要仅打开一个开关就把旧设备切到 v3-only。
- **自托管**：示例地址、房间与签名设置都是占位配置。使用者需部署自己的服务、授权自己的 dot，并保护自己的凭据。免费平台的配额和调度由各平台决定。

Local tests and simulator results do not prove every hardware model, background state, biometric policy, network, or long-running upstream subscription. See [Testing](TESTING.md) for the checks you can repeat.
