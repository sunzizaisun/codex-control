import Foundation
import SwiftUI

public enum AppPreferenceKeys {
    public static let language = "CodexWatch.preference.language"
    public static let appearance = "CodexWatch.preference.appearance"
}

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese
    case english
    case spanish
    case french
    case german
    case japanese
    case korean
    case portuguese
    case italian
    case russian
    case arabic
    case hindi

    public var id: String { rawValue }

    public var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        case .english: Locale(identifier: "en")
        case .spanish: Locale(identifier: "es")
        case .french: Locale(identifier: "fr")
        case .german: Locale(identifier: "de")
        case .japanese: Locale(identifier: "ja")
        case .korean: Locale(identifier: "ko")
        case .portuguese: Locale(identifier: "pt-BR")
        case .italian: Locale(identifier: "it")
        case .russian: Locale(identifier: "ru")
        case .arabic: Locale(identifier: "ar")
        case .hindi: Locale(identifier: "hi")
        }
    }

    public var resolvesToEnglish: Bool {
        resolved == .english
    }

    public func layoutDirection(following systemDirection: LayoutDirection) -> LayoutDirection {
        if self == .system { return systemDirection }
        return self == .arabic ? .rightToLeft : .leftToRight
    }

    public var resolved: AppLanguage {
        guard self == .system else { return self }
        let identifier = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if identifier.hasPrefix("zh") { return .simplifiedChinese }
        if identifier.hasPrefix("es") { return .spanish }
        if identifier.hasPrefix("fr") { return .french }
        if identifier.hasPrefix("de") { return .german }
        if identifier.hasPrefix("ja") { return .japanese }
        if identifier.hasPrefix("ko") { return .korean }
        if identifier.hasPrefix("pt") { return .portuguese }
        if identifier.hasPrefix("it") { return .italian }
        if identifier.hasPrefix("ru") { return .russian }
        if identifier.hasPrefix("ar") { return .arabic }
        if identifier.hasPrefix("hi") { return .hindi }
        return .english
    }

    public var nativeDisplayName: String {
        switch self {
        case .system: "Follow System"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .portuguese: "Português"
        case .italian: "Italiano"
        case .russian: "Русский"
        case .arabic: "العربية"
        case .hindi: "हिन्दी"
        }
    }
}

public enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// A real View must own appearance preferences. Reading colorScheme from an
/// App value captures its default environment, not the Window's live traits.
/// In system mode leave the native environment untouched; only explicit
/// overrides are injected for watchOS custom backgrounds and pushed Lists.
public struct AppAppearanceRoot<Content: View>: View {
    @Environment(\.layoutDirection) private var systemLayoutDirection
    @AppStorage(AppPreferenceKeys.language) private var languageRaw = AppLanguage.system.rawValue
    @AppStorage(AppPreferenceKeys.appearance) private var appearanceRaw = AppAppearance.system.rawValue
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        let language = AppLanguage(rawValue: languageRaw) ?? .system
        let appearance = AppAppearance(rawValue: appearanceRaw) ?? .system
        content
            .environment(\.locale, language.locale)
            .preferredColorScheme(appearance.colorScheme)
            .transformEnvironment(\.colorScheme) { scheme in
                if let explicit = appearance.colorScheme { scheme = explicit }
            }
            // Always write the resolved direction. Leaving a transformed
            // value untouched in System mode can retain an earlier RTL
            // override and mirror a newly English native Form.
            .environment(\.layoutDirection, language.layoutDirection(following: systemLayoutDirection))
    }
}

/// watchOS owns the clock/navigation chrome separately from content traits.
/// Use its public toolbar APIs instead of hiding or drawing over the clock.
public extension View {
    @ViewBuilder func adaptiveWatchNavigationAppearance() -> some View {
        #if os(watchOS)
        modifier(AdaptiveWatchNavigationAppearance())
        #else
        self
        #endif
    }
}

#if os(watchOS)
private struct AdaptiveWatchNavigationAppearance: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content
            .toolbarColorScheme(colorScheme, for: .navigationBar)
            .toolbarForegroundStyle(colorScheme == .light ? Color.black : Color.white, for: .navigationBar)
    }
}
#endif

public enum AppLocalizer {
    private static let english: [String: String] = [
        "正在寻找 Mac": "Looking for Mac",
        "正在连接 %@": "Connecting to %@",
        "已连接 %@": "Connected to %@",
        "Mac 未连接": "Mac Disconnected",
        "远程在线": "Remote Online",
        "远程正在恢复": "Restoring Remote Connection",
        "远程中继在线": "Remote relay online",
        "远程中继正在恢复": "Restoring remote relay",
        "已接通电源，本地控制可用": "On external power — local control is available",
        "电池供电，不保持唤醒": "On battery — sleep is never prevented",
        "%@，远程中继在线": "%@, remote relay online",
        "%@，远程中继正在恢复": "%@, restoring remote relay",
        "%@已运行": "%@ running",
        "%@，正在验证远程中继": "%@, verifying the remote relay",
        "此 iPhone 不支持 Apple Watch 连接": "This iPhone does not support Apple Watch connectivity",
        "请先选择一台可用的 Mac": "Choose an available Mac first",
        "无法创建配对请求": "Could not create the pairing request",
        "Mac 未连接，暂时无法刷新": "Mac is offline; refresh is temporarily unavailable",
        "Mac 使用了较新的协议版本，请更新 iPhone App": "The Mac uses a newer protocol. Update the iPhone app.",
        "Mac 发来的任务快照为空": "The Mac sent an empty task snapshot",
        "Mac 返回了未知错误": "The Mac returned an unknown error",
        "iPhone App 无法读取这个协议版本": "The iPhone app cannot read this protocol version",
        "指令内容为空": "The instruction is empty",
        "发送已过期，执行结果未确认。请查看原任务后再试。": "Delivery expired and execution is unconfirmed. Check the original task before trying again.",
        "找不到这个任务": "This task could not be found",
        "Chat 功能已移除，请使用 Codex 任务": "Chat has been removed. Use a Codex task instead.",
        "审批决定为空": "The approval decision is empty",
        "手表只允许单次批准或拒绝": "Apple Watch only supports Allow Once or Deny",
        "该审批已不在待处理列表中": "This approval is no longer pending",
        "该审批已经过期": "This approval has expired",
        "审批内容校验失败": "Approval verification failed",
        "无法编码审批决定": "Could not encode the approval decision",
        "发送到 Mac 失败：%@": "Could not send to Mac: %@",
        "远程发送失败：%@": "Remote send failed: %@",
        "远程连接正在恢复：%@": "Restoring remote connection: %@",
        "远程快照正在恢复：%@": "Restoring the remote snapshot: %@",
        "无法同步到 Apple Watch：%@": "Could not sync to Apple Watch: %@",
        "Apple Watch 同步内容过大，正在改用公网中继": "The Apple Watch payload is too large; switching to the public relay",
        "Apple Watch 指令内容过大，正在改用公网中继": "The Apple Watch command is too large; switching to the public relay",
        "无法搜索 Mac：%@": "Could not search for Mac: %@",
        "Apple Watch 连接失败：%@": "Apple Watch connection failed: %@",
        "此 Apple Watch 不支持连接": "This Apple Watch does not support connectivity",
        "请更新 Apple Watch App": "Update the Apple Watch app",
        "审批失败": "Approval failed",
        "公网连接正在恢复": "Restoring internet connection",
        "正在启动": "Starting",
        "正在恢复 ChatGPT 桌面接口": "Restoring ChatGPT desktop interface",
        "本地与远程桥接已运行": "Local and remote bridge running",
        "本地 app-server 会话，远程中继在线": "Local app-server session, remote relay online",
        "本地 app-server 会话": "Local app-server session",
        "无法保存操作回执，请在 Mac 上检查后重试。": "Could not save the action receipt. Check your Mac before trying again.",
        "同一消息编号的内容已改变，操作未执行。": "This message ID has different contents. The action was not executed.",
        "上次操作结果未确认，请先检查原任务。": "The previous action's result is unknown. Check the original task first.",
        "操作回执空间已满，请稍后再试。": "Action receipt storage is full. Try again later.",
        "已接入 app-server 会话": "Connected app-server session",
        "本地 app-server 会话，远程中继正在恢复": "Local app-server session, restoring remote relay",
        "本地 app-server 会话已运行": "Local app-server session running",
        "已接入 app-server 会话，远程中继在线": "Connected app-server session, remote relay online",
        "已接入 app-server 会话，远程中继正在恢复": "Connected app-server session, restoring remote relay",
        "已接入 app-server 会话已运行": "Connected app-server session running",
        "本地桥接已运行": "Local bridge running",
        "启动失败": "Startup failed",
        "iPhone 已连接": "iPhone Connected",
        "等待 iPhone": "Waiting for iPhone",
        "Mac 在线": "Mac Online",
        "正在恢复": "Reconnecting",
        "Token 余额": "Token Balance",
        "Token": "Token",
        "下次重置": "Next reset",
        "下次重置 %@": "Next reset %@",
        "设置": "Settings",
        "Codex 控制": "Codex Control",
        "手表": "Watch",
        "正在进行": "In Progress",
        "最近任务": "Recent Tasks",
        "处理审批": "Review Approvals",
        "正在发送…": "Sending…",
        "发送": "Send",
        "告诉 Codex 接下来做什么": "Tell Codex what to do next",
        "运行中": "Running",
        "等待批准": "Waiting for Approval",
        "空闲": "Idle",
        "已完成": "Completed",
        "失败": "Failed",
        "处理中": "In Progress",
        "刚刚": "just now",
        "同步时间 %@": "Synced %@",
        "最近同步 %@": "Last sync %@",
        "Codex 等待审批": "Codex Needs Approval",
        "打开 Codex 控制，在 iPhone 或 Apple Watch 上查看并确认。": "Open Codex Control to review and decide on iPhone or Apple Watch.",
        "批准 Codex：%@": "Approve Codex: %@",
        "在 Apple Watch 上确认批准": "Confirm approval on Apple Watch",
        "这个 Codex 请求无法通过 Apple Watch 批准。": "This Codex request cannot be approved from Apple Watch.",
        "审批请求已不再等待处理。": "The approval request is no longer pending.",
        "审批请求已过期。": "The approval request expired.",
        "审批内容已经变化，请重新检查。": "The approval request changed. Review it again.",
        "Codex 没有提供这个审批选项。": "Codex did not offer that approval option.",
        "远程中继返回了无效响应": "The remote relay returned an invalid response",
        "远程中继错误（%@）": "Remote relay error (%@)",
        "远程中继身份验证失败": "Remote relay authentication failed",
        "远程数据校验失败": "Remote data verification failed",
        "新对话": "New Chat",
        "ChatGPT 聊天": "ChatGPT Chat",
        "ChatGPT 没有返回文字回复": "ChatGPT returned no text reply",
        "已取消 ChatGPT 快捷指令": "ChatGPT Shortcut was cancelled",
        "ChatGPT 快捷指令运行失败": "ChatGPT Shortcut failed",
        "旧版快捷指令对话已停用，请新建 Chat": "The legacy Shortcut chat is disabled. Start a new Chat.",
        "无法创建 ChatGPT 快捷指令": "Could not create the ChatGPT Shortcut request",
        "请先安装 Codex Control Chat 快捷指令": "Install the Codex Control Chat shortcut first",
        "新建 Codex": "New Codex",
        "正在连接 ChatGPT…": "Connecting to ChatGPT…",
        "正在连接 ChatGPT，正在验证远程中继": "Connecting to ChatGPT and verifying the remote relay",
        "请先连接 Mac 或配置远程 Chat 网关": "Connect a Mac or configure a remote Chat gateway first",
        "聊天": "Chats",
        "还没有对话": "No chats yet",
        "点右上角的新对话开始。": "Tap New Chat in the top right to begin.",
        "会创建并保存到你的 ChatGPT 历史记录。": "This creates a chat saved to your ChatGPT history.",
        "已发送到 ChatGPT。回复会保存在你的 ChatGPT 历史记录中。": "Sent to ChatGPT. The reply is saved in your ChatGPT history.",
        "输入消息": "Enter a message",
        "发一条消息": "Enter a message",
        "开始对话": "Start Chat",
        "取消": "Cancel",
        "对话": "Conversation",
        "任务详情": "Task Details",
        "当前进度": "Current Progress",
        "模型": "Model",
        "工作目录": "Working Directory",
        "继续对话": "Continue Conversation",
        "此任务正在 ChatGPT 桌面端中运行。请通过 ChatGPT Remote 继续；本应用会同步状态与审批。": "This task is running in ChatGPT desktop. Continue it with ChatGPT Remote; this app will keep its status and approvals in sync.",
        "ChatGPT 桌面端未运行": "ChatGPT desktop is not running",
        "ChatGPT 桌面接口暂不可用，远程中继保持在线": "ChatGPT desktop is unavailable; the remote relay remains online",
        "请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试": "Allow Agent Bridge in System Settings > Privacy & Security > Accessibility, then try again.",
        "桌面控制仅在接通电源时启用": "Desktop control is enabled only while the Mac is connected to power",
        "当前 ChatGPT 桌面端未启用 Quick Chat；标准新对话会进入 Work，已停止发送以避免消耗 Codex/Work 额度": "Quick Chat is not enabled in this ChatGPT desktop build. Standard New Chat opens Work, so sending was stopped to avoid using Codex/Work quota.",
        "Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试": "Google Chrome is not running. Open Chrome, sign in to chatgpt.com, then try again.",
        "请先在 Google Chrome 登录 chatgpt.com，再从 iPhone 或 Apple Watch 发送 Chat": "Sign in to chatgpt.com in Google Chrome first, then send Chat from iPhone or Apple Watch.",
        "Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com": "Chrome Chat Bridge is not connected. Load the extension in Chrome and open chatgpt.com.",
        "此 ChatGPT Chat 已绑定远程浏览器网关，Mac 本地桥接器不会把它送入 Work 或 Codex": "This ChatGPT Chat is pinned to the remote browser gateway. The Mac bridge will not route it into Work or Codex.",
        "ChatGPT 桌面控制通道不可用": "ChatGPT desktop control is unavailable",
        "无法连接 ChatGPT 桌面控制：%@": "Could not connect to ChatGPT desktop control: %@",
        "ChatGPT 桌面控制协议错误：%@": "ChatGPT desktop control protocol error: %@",
        "没有桌面窗口正在管理这个任务": "No desktop window is managing this task",
        "无法在 ChatGPT 中打开目标任务": "Could not open the target task in ChatGPT",
        "找不到 ChatGPT 消息输入框": "Could not find the ChatGPT message composer",
        "目标任务中已有未发送的草稿，为避免覆盖已取消发送": "The target task already has an unsent draft, so sending was cancelled to avoid overwriting it",
        "找不到 ChatGPT 发送按钮": "Could not find the ChatGPT send button",
        "无法控制 ChatGPT 桌面端：%@": "Could not control ChatGPT desktop: %@",
        "正在可靠发送…": "Sending reliably…",
        "消息": "Message",
        "你": "You",
        "好": "OK",
        "状态": "Status",
        "审批": "Approvals",
        "待审批": "Approvals",
        "提示": "Notice",
        "全部处理完了": "All caught up",
        "由 Mac Bridge 接管的新权限请求会同步到 Apple Watch。": "New permission requests handled by the Mac bridge are sent to Apple Watch.",
        "剩余": "Left",
        "等待额度同步": "Waiting for usage data",
        "可重置 %@ 次": "%@ resets available",
        "设备连接": "Connections",
        "设备": "Devices",
        "动态配对二维码": "Dynamic Pairing QR Code",
        "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。": "Scan this code in iPhone Connections, or enter the six-digit code above. The QR code updates whenever the code changes.",
        "iPhone 状态": "iPhone Status",
        "已配对": "Paired",
        "等待配对": "Ready to Pair",
        "重置后，下一台 iPhone 扫码或输入验证码即可配对。": "After reset, the next iPhone can pair by scanning the code or entering the six-digit code.",
        "iPhone 已配对": "iPhone Paired",
        "配对二维码已移至设置的设备连接中": "The pairing QR code is now in Settings › Connections.",
        "扫描二维码": "Scan QR Code",
        "此设备不支持扫码": "This device does not support QR scanning",
        "无法读取配对二维码": "Could not read this pairing QR code",
        "配对二维码已过期，请在 Mac 上更新": "This pairing QR code has expired. Refresh it on your Mac.",
        "选择 Mac": "Choose Mac",
        "正在搜索…": "Searching…",
        "立即连接": "Connect Now",
        "已开启自动重连，无需验证码": "Automatic reconnection is on — no code needed",
        "Mac 动态配对码（首次连接）": "Mac pairing code (first connection)",
        "首次输入 Mac 显示的动态码；以后会自动重连": "Enter the code shown on your Mac once; future connections reconnect automatically.",
        "配对 iPhone": "Pair iPhone",
        "配对或重新连接 iPhone": "Pair or Reconnect iPhone",
        "正在连接…": "Connecting…",
        "Mac 没有接受配对请求，请确认最新六码和本地网络权限": "Mac did not accept the pairing request. Check the newest code and Local Network permission.",
        "Mac 拒绝了配对请求，请确认最新六码和本地网络权限": "Mac rejected the pairing request. Check the newest code and Local Network permission.",
        "有效期 %@": "Expires in %@",
        "自动更新": "Updates automatically",
        "更新验证码": "New Code",
        "重置 iPhone 配对": "Reset iPhone Pairing",
        "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。": "Enter this code in Connections on iPhone. After pairing, its Apple Watch automatically receives the same connection.",
        "自动保持连接": "Always reconnect",
        "暂无受控任务": "No managed tasks yet",
        "未知": "Unknown",
        "正在读取运行中的任务，请稍后重试": "Loading the active task. Try again shortly.",
        "待处理": "Pending",
        "请在 Apple Watch 上批准或拒绝": "Approve or deny on Apple Watch",
        "iPhone 可用 Face ID；Apple Watch 需佩戴后批准": "Use Face ID on iPhone, or wear Apple Watch to approve",
        "在 iPhone 上确认 Codex：%@": "Confirm Codex on iPhone: %@",
        "需要 Face ID 才能批准此请求": "Face ID is required to approve this request",
        "iPhone 批准会先要求 Face ID": "iPhone approval will request Face ID first",
        "佩戴手表并双击侧边按钮完成批准": "Wear your Apple Watch and double-click the side button to approve",
        "显示": "Display",
        "语言": "Language",
        "跟随系统": "Follow System",
        "简体中文": "Simplified Chinese",
        "英语": "English",
        "外观": "Appearance",
        "浅色": "Light",
        "深色": "Dark",
        "自动重连与离线队列始终开启": "Automatic reconnection and offline delivery are always on",
        "审批同步": "Approval Sync",
        "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "Permission requests from the active ChatGPT desktop task sync to iPhone and Apple Watch; decisions are returned to the original task.",
        "实时活动": "Live Activities",
        "实时活动已开启": "Live Activities are on",
        "实时活动已关闭": "Live Activities are off",
        "有运行中任务时，会优先推荐到 iPhone 锁屏和 Apple Watch 智能叠放。": "When a task is running, it is prioritized for the iPhone Lock Screen and Apple Watch Smart Stack.",
        "完成": "Done",
        "命令": "Command",
        "访问范围": "Access Scope",
        "运行命令": "Run Command",
        "修改文件": "Modify Files",
        "请求权限": "Request Permission",
        "需要确认": "Confirmation Required",
        "Codex 希望运行一条命令": "Codex wants to run a command",
        "Codex 希望应用文件更改": "Codex wants to apply file changes",
        "Codex 希望扩大本次任务的访问范围": "Codex wants broader access for this task",
        "Codex 正在等待确认": "Codex is waiting for confirmation",
        "ChatGPT 希望使用一个外部工具": "ChatGPT wants to use an external tool",
        "网络访问": "Network Access",
        "拒绝": "Deny",
        "批准一次": "Allow Once",
        "发生错误": "Something went wrong",
        "未知错误": "Unknown error",
        "自动可信连接": "Trusted Connection",
        "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复": "After the first connection, this iPhone is remembered without a code and reconnects automatically.",
        "Codex 任务": "Codex Tasks",
        "还没有任务": "No tasks yet",
        "启动新任务": "Start New Task",
        "让 Codex 做什么？": "What should Codex do?",
        "启动受控任务": "Start Managed Task",
        "发送指令": "Send Instruction",
        "Watch 批准": "Approve on Watch",
        "额度与重置": "Usage & Reset",
        "今日 Token 消耗": "Today's Token Usage",
        "重置日期": "Reset Date",
        "重置卡": "Reset Cards",
        "到期 %@": "Expires %@",
        "无到期日": "No expiration",
        "使用": "Use",
        "确认使用重置卡？": "Use this reset card?",
        "这会消耗一张重置卡，并立即重置符合条件的额度窗口。": "This uses one reset card and immediately resets eligible rate-limit windows.",
        "确认": "Confirm",
        "用量不可用": "Usage unavailable",
        "重置完成": "Reset complete",
        "当前没有可重置的额度窗口": "No eligible limit to reset",
        "没有可用重置卡": "No reset card available",
        "无法创建重置请求": "Could not create the reset request",
        "公网快照正在恢复": "Restoring the public snapshot",
        "此重置请求已完成": "This reset request was already completed",
    ]

    public static func text(_ key: String) -> String {
        text(key, language: selectedLanguage)
    }

    public static func text(_ key: String, language: AppLanguage) -> String {
        if let value = CommandRecoveryTranslations.text(key, language: language) { return value }
        if let value = FeatureTranslations.text(key, language: language) { return value }
        switch language.resolved {
        case .simplifiedChinese:
            return key
        case .english:
            return english[key] ?? key
        default:
            return AdditionalTranslations.values(for: language)[key]
                ?? english[key]
                ?? key
        }
    }

    /// Localizes system-generated approval labels that may have been created
    /// on another device using a different language.  User-provided command
    /// reasons and task titles are intentionally left untouched; only the
    /// small, stable set of protocol presentation strings is normalized.
    public static func localizedRemote(_ value: String, language: AppLanguage? = nil) -> String {
        guard let key = remotePresentationKeys.first(where: { candidate in
            if candidate == value || english[candidate] == value { return true }
            return supportedRemoteLanguages.contains { language in
                AdditionalTranslations.values(for: language)[candidate] == value
            }
        }) else {
            return value
        }
        return text(key, language: language ?? selectedLanguage)
    }

    private static let supportedRemoteLanguages: [AppLanguage] = [
        .spanish, .french, .german, .japanese, .korean, .portuguese,
        .italian, .russian, .arabic, .hindi,
    ]

    private static let remotePresentationKeys: [String] = [
        "运行命令",
        "修改文件",
        "请求权限",
        "需要确认",
        "Codex 希望运行一条命令",
        "Codex 希望应用文件更改",
        "Codex 希望扩大本次任务的访问范围",
        "Codex 正在等待确认",
        "ChatGPT 希望使用一个外部工具",
        "网络访问",
    ]

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let format = text(key)
        return String(format: format, locale: currentLanguage.locale, arguments: arguments)
    }

    public static func relativeTime(to date: Date, from reference: Date = Date()) -> String {
        let interval = date.timeIntervalSince(reference)
        if abs(interval) < 5 {
            return text("刚刚")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = currentLanguage.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    public static func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = currentLanguage.locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = currentLanguage.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static var currentLanguage: AppLanguage {
        selectedLanguage
    }

    /// UI previews can request a language without mutating the simulator's
    /// system locale or the user's persisted preference. Production builds
    /// continue to use the selected preference exactly as before.
    private static var selectedLanguage: AppLanguage {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-UIPreview") {
            for option in AppLanguage.allCases where option != .system {
                if arguments.contains(option.rawValue) || arguments.contains("-\(option.rawValue)") {
                    return option
                }
            }
        }
        let raw = UserDefaults.standard.string(forKey: AppPreferenceKeys.language)
        return (AppLanguage(rawValue: raw ?? "") ?? .system).resolved
    }
}
