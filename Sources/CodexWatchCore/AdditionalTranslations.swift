import Foundation

/// Translations for the user-facing control surface.  Less common diagnostic
/// strings intentionally fall back to the complete English catalog so a
/// selected language never produces a mixed Chinese/English screen.
enum AdditionalTranslations {
    static func values(for language: AppLanguage) -> [String: String] {
        let translated: [String: String]
        switch language.resolved {
        case .spanish:
            translated = spanish
        case .french:
            translated = french
        case .german:
            translated = german
        case .japanese:
            translated = japanese
        case .korean:
            translated = korean
        case .portuguese:
            translated = portuguese
        case .italian:
            translated = italian
        case .russian:
            translated = russian
        case .arabic:
            translated = arabic
        case .hindi:
            translated = hindi
        default:
            translated = [:]
        }
        return common(for: language.resolved)
            .merging(operational(for: language.resolved)) { _, languageValue in languageValue }
            .merging(recovery(for: language.resolved)) { _, languageValue in languageValue }
            .merging(macSurface(for: language.resolved)) { _, languageValue in languageValue }
            .merging(translated) { _, languageValue in languageValue }
            .merging([
                "会创建并保存到你的 ChatGPT 历史记录。": historyDescription(for: language.resolved),
            ]) { _, languageValue in languageValue }
    }

    private static func historyDescription(for language: AppLanguage) -> String {
        switch language {
        case .spanish:
            "Esto crea un chat y lo guarda en tu historial de ChatGPT."
        case .french:
            "Cette action crée un chat enregistré dans votre historique ChatGPT."
        case .german:
            "Dadurch wird ein Chat erstellt und in deinem ChatGPT-Verlauf gespeichert."
        case .japanese:
            "Chat を作成し、ChatGPT の履歴に保存します。"
        case .korean:
            "Chat을 만들고 ChatGPT 기록에 저장합니다."
        case .portuguese:
            "Isso cria um chat salvo no seu histórico do ChatGPT."
        case .italian:
            "Crea una chat e la salva nella cronologia di ChatGPT."
        case .russian:
            "Будет создан чат и сохранён в истории ChatGPT."
        case .arabic:
            "سيؤدي ذلك إلى إنشاء محادثة وحفظها في سجل ChatGPT."
        case .hindi:
            "यह चैट बनाएगा और उसे आपके ChatGPT इतिहास में सहेजेगा।"
        default:
            "This creates a chat saved to your ChatGPT history."
        }
    }

    /// Operational dashboard strings are shared by iPhone, Watch, and Mac.
    /// Keep them in one small catalog so a system language never falls back
    /// to an English fragment in an otherwise translated status card.
    private static func operational(for language: AppLanguage) -> [String: String] {
        switch language {
        case .spanish:
            return [
                "可重置 %@ 次": "%@ reinicios disponibles", "同步时间 %@": "Sincronizado %@", "最近同步 %@": "Última sincronización %@",
                "远程中继在线": "Relay remoto conectado", "远程中继正在恢复": "Restableciendo el relay remoto", "已接通电源，本地控制可用": "Con alimentación externa: control local disponible", "电池供电，不保持唤醒": "Con batería: no se impide el reposo",
                "Mac 拒绝了配对请求，请确认最新六码和本地网络权限": "Mac rechazó la solicitud de enlace. Comprueba el código más reciente y el permiso de red local",
                "Mac 没有接受配对请求，请确认最新六码和本地网络权限": "Mac no aceptó la solicitud de enlace. Comprueba el código más reciente y el permiso de red local",
                "有效期 %@": "Caduca en %@", "自动更新": "Actualización automática", "更新验证码": "Nuevo código", "重置 iPhone 配对": "Restablecer enlace del iPhone",
                "配对二维码已过期，请在 Mac 上更新": "El código QR de enlace ha caducado; actualízalo en el Mac"
            ]
        case .french:
            return [
                "可重置 %@ 次": "%@ réinitialisations disponibles", "同步时间 %@": "Synchronisé %@", "最近同步 %@": "Dernière synchronisation %@",
                "远程中继在线": "Relais distant connecté", "远程中继正在恢复": "Rétablissement du relais distant", "已接通电源，本地控制可用": "Sur secteur : contrôle local disponible", "电池供电，不保持唤醒": "Sur batterie : la veille n’est pas empêchée",
                "Mac 拒绝了配对请求，请确认最新六码和本地网络权限": "Le Mac a refusé la demande de jumelage. Vérifiez le dernier code et l’accès au réseau local",
                "Mac 没有接受配对请求，请确认最新六码和本地网络权限": "Le Mac n’a pas accepté la demande de jumelage. Vérifiez le dernier code et l’accès au réseau local",
                "有效期 %@": "Expire dans %@", "自动更新": "Mise à jour automatique", "更新验证码": "Nouveau code", "重置 iPhone 配对": "Réinitialiser le jumelage de l’iPhone",
                "配对二维码已过期，请在 Mac 上更新": "Le QR de jumelage a expiré ; actualisez-le sur le Mac"
            ]
        case .german:
            return [
                "可重置 %@ 次": "%@ Zurücksetzungen verfügbar", "同步时间 %@": "Synchronisiert %@", "最近同步 %@": "Letzte Synchronisierung %@",
                "远程中继在线": "Remote-Relay online", "远程中继正在恢复": "Remote-Relay wird wiederhergestellt", "已接通电源，本地控制可用": "Am Strom: lokale Steuerung verfügbar", "电池供电，不保持唤醒": "Im Akkubetrieb: Ruhezustand wird nicht verhindert",
                "Mac 拒绝了配对请求，请确认最新六码和本地网络权限": "Der Mac hat die Kopplungsanfrage abgelehnt. Prüfe den neuesten Code und den lokalen Netzwerkzugriff",
                "Mac 没有接受配对请求，请确认最新六码和本地网络权限": "Der Mac hat die Kopplungsanfrage nicht angenommen. Prüfe den neuesten Code und den lokalen Netzwerkzugriff",
                "有效期 %@": "Läuft in %@ ab", "自动更新": "Automatische Aktualisierung", "更新验证码": "Neuer Code", "重置 iPhone 配对": "iPhone-Kopplung zurücksetzen",
                "配对二维码已过期，请在 Mac 上更新": "Der Kopplungs-QR-Code ist abgelaufen; aktualisiere ihn auf dem Mac"
            ]
        case .japanese:
            return [
                "可重置 %@ 次": "%@ 回リセット可能", "同步时间 %@": "同期 %@", "最近同步 %@": "最終同期 %@",
                "远程中继在线": "リモートリレー接続中", "远程中继正在恢复": "リモートリレーを復旧中", "已接通电源，本地控制可用": "電源接続中: ローカル制御を利用できます", "电池供电，不保持唤醒": "バッテリー駆動: スリープを防止しません",
                "Mac 拒绝了配对请求，请确认最新六码和本地网络权限": "Mac がペアリング要求を拒否しました。最新のコードとローカルネットワーク権限を確認してください",
                "Mac 没有接受配对请求，请确认最新六码和本地网络权限": "Mac がペアリング要求を受け付けませんでした。最新のコードとローカルネットワーク権限を確認してください",
                "有效期 %@": "%@ まで有効", "自动更新": "自動更新", "更新验证码": "新しいコード", "重置 iPhone 配对": "iPhone のペアリングをリセット",
                "配对二维码已过期，请在 Mac 上更新": "ペアリング QR コードの有効期限が切れました。Mac で更新してください"
            ]
        case .korean:
            return [
                "可重置 %@ 次": "%@회 재설정 가능", "同步时间 %@": "동기화됨 %@", "最近同步 %@": "최근 동기화 %@",
                "远程中继在线": "원격 릴레이 온라인", "远程中继正在恢复": "원격 릴레이 복구 중", "已接通电源，本地控制可用": "전원 연결됨: 로컬 제어 사용 가능", "电池供电，不保持唤醒": "배터리 사용: 잠자기를 막지 않음",
                "Mac 拒绝了配对请求，请确认最新六码和本地网络权限": "Mac에서 페어링 요청을 거부했습니다. 최신 코드와 로컬 네트워크 권한을 확인하세요",
                "Mac 没有接受配对请求，请确认最新六码和本地网络权限": "Mac에서 페어링 요청을 수락하지 않았습니다. 최신 코드와 로컬 네트워크 권한을 확인하세요",
                "有效期 %@": "%@ 후 만료", "自动更新": "자동 업데이트", "更新验证码": "새 코드", "重置 iPhone 配对": "iPhone 페어링 재설정",
                "配对二维码已过期，请在 Mac 上更新": "페어링 QR 코드가 만료되었습니다. Mac에서 업데이트하세요"
            ]
        case .portuguese:
            return [
                "可重置 %@ 次": "%@ redefinições disponíveis", "同步时间 %@": "Sincronizado %@", "最近同步 %@": "Última sincronização %@",
                "远程中继在线": "Relay remoto conectado", "远程中继正在恢复": "Restaurando o relay remoto", "已接通电源，本地控制可用": "Ligado à energia: controle local disponível", "电池供电，不保持唤醒": "Na bateria: o repouso não é impedido",
                "Mac 拒绝了配对请求，请确认最新六码和本地网络权限": "O Mac recusou o pedido de pareamento. Verifique o código mais recente e a permissão de rede local",
                "Mac 没有接受配对请求，请确认最新六码和本地网络权限": "O Mac não aceitou o pedido de pareamento. Verifique o código mais recente e a permissão de rede local",
                "有效期 %@": "Expira em %@", "自动更新": "Atualização automática", "更新验证码": "Novo código", "重置 iPhone 配对": "Redefinir pareamento do iPhone",
                "配对二维码已过期，请在 Mac 上更新": "O QR de pareamento expirou; atualize-o no Mac"
            ]
        case .italian:
            return [
                "可重置 %@ 次": "%@ reimpostazioni disponibili", "同步时间 %@": "Sincronizzato %@", "最近同步 %@": "Ultima sincronizzazione %@",
                "远程中继在线": "Relay remoto online", "远程中继正在恢复": "Ripristino del relay remoto", "已接通电源，本地控制可用": "Alimentazione collegata: controllo locale disponibile", "电池供电，不保持唤醒": "A batteria: la sospensione non viene impedita",
                "Mac 拒绝了配对请求，请确认最新六码和本地网络权限": "Il Mac ha rifiutato la richiesta di abbinamento. Controlla il codice più recente e l’accesso alla rete locale",
                "Mac 没有接受配对请求，请确认最新六码和本地网络权限": "Il Mac non ha accettato la richiesta di abbinamento. Controlla il codice più recente e l’accesso alla rete locale",
                "有效期 %@": "Scade tra %@", "自动更新": "Aggiornamento automatico", "更新验证码": "Nuovo codice", "重置 iPhone 配对": "Reimposta abbinamento iPhone",
                "配对二维码已过期，请在 Mac 上更新": "Il QR di abbinamento è scaduto; aggiornalo sul Mac"
            ]
        case .russian:
            return [
                "可重置 %@ 次": "Доступно сбросов: %@", "同步时间 %@": "Синхронизировано %@", "最近同步 %@": "Последняя синхронизация %@",
                "远程中继在线": "Удалённый relay подключён", "远程中继正在恢复": "Восстановление удалённого relay", "已接通电源，本地控制可用": "Питание подключено: локальное управление доступно", "电池供电，不保持唤醒": "Питание от батареи: сон не блокируется",
                "Mac 拒绝了配对请求，请确认最新六码和本地网络权限": "Mac отклонил запрос на связывание. Проверьте последний код и доступ к локальной сети",
                "Mac 没有接受配对请求，请确认最新六码和本地网络权限": "Mac не принял запрос на связывание. Проверьте последний код и доступ к локальной сети",
                "有效期 %@": "Истекает через %@", "自动更新": "Автообновление", "更新验证码": "Новый код", "重置 iPhone 配对": "Сбросить связь с iPhone",
                "配对二维码已过期，请在 Mac 上更新": "QR-код связывания истёк; обновите его на Mac"
            ]
        case .arabic:
            return [
                "可重置 %@ 次": "إعادة التعيين المتاحة: %@", "同步时间 %@": "تمت المزامنة %@", "最近同步 %@": "آخر مزامنة %@",
                "远程中继在线": "الترحيل البعيد متصل", "远程中继正在恢复": "جارٍ استعادة الترحيل البعيد", "已接通电源，本地控制可用": "متصل بالطاقة: التحكم المحلي متاح", "电池供电，不保持唤醒": "على البطارية: لا يتم منع السكون",
                "Mac 拒绝了配对请求，请确认最新六码和本地网络权限": "رفض Mac طلب الاقتران. تحقق من أحدث رمز ومنح إذن الشبكة المحلية",
                "Mac 没有接受配对请求，请确认最新六码和本地网络权限": "لم يقبل Mac طلب الاقتران. تحقق من أحدث رمز ومنح إذن الشبكة المحلية",
                "有效期 %@": "تنتهي خلال %@", "自动更新": "تحديث تلقائي", "更新验证码": "رمز جديد", "重置 iPhone 配对": "إعادة اقتران iPhone",
                "配对二维码已过期，请在 Mac 上更新": "انتهت صلاحية رمز QR للاقتران؛ حدّثه على Mac"
            ]
        case .hindi:
            return [
                "可重置 %@ 次": "%@ रीसेट उपलब्ध", "同步时间 %@": "सिंक हुआ %@", "最近同步 %@": "अंतिम सिंक %@",
                "远程中继在线": "रिमोट रिले ऑनलाइन", "远程中继正在恢复": "रिमोट रिले बहाल हो रहा है", "已接通电源，本地控制可用": "बाहरी पावर पर: लोकल नियंत्रण उपलब्ध", "电池供电，不保持唤醒": "बैटरी पर: स्लीप रोका नहीं जाता",
                "Mac 拒绝了配对请求，请确认最新六码和本地网络权限": "Mac ने पेयरिंग अनुरोध अस्वीकार किया। नवीनतम कोड और लोकल नेटवर्क अनुमति जाँचें",
                "Mac 没有接受配对请求，请确认最新六码和本地网络权限": "Mac ने पेयरिंग अनुरोध स्वीकार नहीं किया। नवीनतम कोड और लोकल नेटवर्क अनुमति जाँचें",
                "有效期 %@": "%@ में समाप्त", "自动更新": "स्वचालित अपडेट", "更新验证码": "नया कोड", "重置 iPhone 配对": "iPhone पेयरिंग रीसेट करें",
                "配对二维码已过期，请在 Mac 上更新": "पेयरिंग QR कोड की अवधि समाप्त हो गई; Mac पर अपडेट करें"
            ]
        default:
            return [:]
        }
    }

    private static func recovery(for language: AppLanguage) -> [String: String] {
        switch language {
        case .spanish:
            return [
                "正在恢复 ChatGPT 桌面接口": "Restableciendo la interfaz de ChatGPT para escritorio",
                "本地 app-server 会话已运行": "La sesión local de app-server está activa",
            ]
        case .french:
            return [
                "正在恢复 ChatGPT 桌面接口": "Restauration de l’interface ChatGPT de bureau",
                "本地 app-server 会话已运行": "La session app-server locale est active",
            ]
        case .german:
            return [
                "正在恢复 ChatGPT 桌面接口": "ChatGPT-Desktop-Schnittstelle wird wiederhergestellt",
                "本地 app-server 会话已运行": "Lokale app-server-Sitzung läuft",
            ]
        case .japanese:
            return [
                "正在恢复 ChatGPT 桌面接口": "ChatGPT デスクトップインターフェースを復旧中",
                "本地 app-server 会话已运行": "ローカル app-server セッションは実行中です",
            ]
        case .korean:
            return [
                "正在恢复 ChatGPT 桌面接口": "ChatGPT 데스크톱 인터페이스 복구 중",
                "本地 app-server 会话已运行": "로컬 app-server 세션 실행 중",
            ]
        case .portuguese:
            return [
                "正在恢复 ChatGPT 桌面接口": "Restaurando a interface do ChatGPT para desktop",
                "本地 app-server 会话已运行": "A sessão local do app-server está ativa",
            ]
        case .italian:
            return [
                "正在恢复 ChatGPT 桌面接口": "Ripristino dell’interfaccia ChatGPT desktop",
                "本地 app-server 会话已运行": "La sessione app-server locale è attiva",
            ]
        case .russian:
            return [
                "正在恢复 ChatGPT 桌面接口": "Восстановление интерфейса ChatGPT для компьютера",
                "本地 app-server 会话已运行": "Локальный сеанс app-server запущен",
            ]
        case .arabic:
            return [
                "正在恢复 ChatGPT 桌面接口": "جارٍ استعادة واجهة ChatGPT لسطح المكتب",
                "本地 app-server 会话已运行": "جلسة app-server المحلية قيد التشغيل",
            ]
        case .hindi:
            return [
                "正在恢复 ChatGPT 桌面接口": "ChatGPT डेस्कटॉप इंटरफ़ेस पुनर्स्थापित हो रहा है",
                "本地 app-server 会话已运行": "स्थानीय app-server सत्र चल रहा है",
            ]
        default:
            return [:]
        }
    }

    /// Mac has a denser control surface than the phone/watch views. Keep its
    /// pairing, desktop-control, and task-management copy in the same catalog
    /// so selecting a non-English language never exposes an English-only row
    /// or error in an otherwise translated Mac window.
    private static func macSurface(for language: AppLanguage) -> [String: String] {
        switch language {
        case .spanish:
            return [
                "%@，正在验证远程中继": "%@, verificando el relay remoto",
                "ChatGPT 桌面接口暂不可用，远程中继保持在线": "La interfaz de escritorio de ChatGPT no está disponible; el relay remoto sigue conectado",
                "ChatGPT 桌面控制协议错误：%@": "Error de protocolo del control de escritorio de ChatGPT: %@",
                "ChatGPT 桌面控制通道不可用": "El canal de control de escritorio de ChatGPT no está disponible",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "Las solicitudes de permisos de la tarea de ChatGPT se sincronizan con el iPhone y el Apple Watch; la decisión vuelve a la tarea original.",
                "ChatGPT 桌面端未运行": "ChatGPT para escritorio no está en ejecución",
                "Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com": "Chrome Chat Bridge no está conectado; carga la extensión en Chrome y abre chatgpt.com",
                "Codex 任务": "Tareas de Codex",
                "设备": "Dispositivos",
                "Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试": "Google Chrome no está en ejecución; ábrelo, inicia sesión en chatgpt.com y vuelve a intentarlo",
                "Mac 动态配对码（首次连接）": "Código de enlace del Mac (primera conexión)",
                "Token 余额": "Saldo de tokens",
                "Watch 批准": "Aprobar en el Watch",
                "iPhone 已配对": "iPhone enlazado",
                "任务详情": "Detalles de la tarea",
                "动态配对二维码": "Código QR de enlace dinámico",
                "发生错误": "Se produjo un error",
                "发送": "Enviar",
                "发送指令": "Enviar instrucción",
                "启动受控任务": "Iniciar tarea controlada",
                "启动新任务": "Iniciar nueva tarea",
                "告诉 Codex 接下来做什么": "Dile a Codex qué hacer después",
                "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。": "Escanea este código en Conexiones del iPhone o introduce los seis dígitos de arriba. El QR se actualiza con el código.",
                "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。": "Introduce este código en Conexiones del iPhone. Cuando se enlace, su Apple Watch usará la misma conexión.",
                "当前 ChatGPT 桌面端未启用 Quick Chat；标准新对话会进入 Work，已停止发送以避免消耗 Codex/Work 额度": "Quick Chat no está habilitado en ChatGPT para escritorio; el chat estándar abriría Work. Se detuvo el envío para no consumir cuota de Codex/Work",
                "批准 Codex：%@": "Aprobar Codex: %@",
                "找不到 ChatGPT 发送按钮": "No se encontró el botón Enviar de ChatGPT",
                "找不到 ChatGPT 消息输入框": "No se encontró el campo de mensaje de ChatGPT",
                "无法在 ChatGPT 中打开目标任务": "No se pudo abrir la tarea en ChatGPT",
                "无法控制 ChatGPT 桌面端：%@": "No se pudo controlar ChatGPT para escritorio: %@",
                "无法连接 ChatGPT 桌面控制：%@": "No se pudo conectar al control de escritorio de ChatGPT: %@",
                "桌面控制仅在接通电源时启用": "El control de escritorio solo está activo con el Mac conectado a la corriente",
                "正在恢复 ChatGPT 桌面接口": "Restableciendo la interfaz de ChatGPT para escritorio",
                "正在连接 ChatGPT，正在验证远程中继": "Conectando con ChatGPT y verificando el relay remoto",
                "此 ChatGPT Chat 已绑定远程浏览器网关，Mac 本地桥接器不会把它送入 Work 或 Codex": "Este Chat de ChatGPT usa el gateway de navegador remoto; el puente del Mac no lo enviará a Work ni Codex",
                "没有桌面窗口正在管理这个任务": "Ninguna ventana de escritorio gestiona esta tarea",
                "目标任务中已有未发送的草稿，为避免覆盖已取消发送": "La tarea ya tiene un borrador sin enviar; se canceló para no sobrescribirlo",
                "自动可信连接": "Conexión de confianza automática",
                "让 Codex 做什么？": "¿Qué debe hacer Codex?",
                "请先在 Google Chrome 登录 chatgpt.com，再从 iPhone 或 Apple Watch 发送 Chat": "Inicia sesión primero en chatgpt.com con Google Chrome y luego envía el Chat desde el iPhone o Apple Watch",
                "请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试": "Permite Agent Bridge en Ajustes del Sistema > Privacidad y seguridad > Accesibilidad y vuelve a intentarlo",
                "还没有任务": "Aún no hay tareas",
                "配对二维码已移至设置的设备连接中": "El QR de enlace ahora está en Ajustes › Conexiones",
                "重置后，下一台 iPhone 扫码或输入验证码即可配对。": "Tras restablecer, el siguiente iPhone puede enlazarse escaneando el código o introduciendo los seis dígitos.",
                "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复": "Después de la primera conexión, este iPhone queda guardado; se recuperará sin código tras una desconexión",
            ]
        case .french:
            return [
                "%@，正在验证远程中继": "%@, vérification du relais distant",
                "ChatGPT 桌面接口暂不可用，远程中继保持在线": "L’interface ChatGPT de bureau est indisponible ; le relais distant reste connecté",
                "ChatGPT 桌面控制协议错误：%@": "Erreur de protocole du contrôle ChatGPT de bureau : %@",
                "ChatGPT 桌面控制通道不可用": "Le canal de contrôle ChatGPT de bureau est indisponible",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "Les demandes d’autorisation de la tâche ChatGPT sont synchronisées avec l’iPhone et l’Apple Watch ; la décision revient à la tâche d’origine.",
                "ChatGPT 桌面端未运行": "ChatGPT de bureau n’est pas lancé",
                "Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com": "Chrome Chat Bridge n’est pas connecté ; chargez l’extension dans Chrome et ouvrez chatgpt.com",
                "Codex 任务": "Tâches Codex",
                "设备": "Appareils",
                "Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试": "Google Chrome n’est pas lancé ; ouvrez-le, connectez-vous à chatgpt.com, puis réessayez",
                "Mac 动态配对码（首次连接）": "Code de jumelage du Mac (première connexion)",
                "Token 余额": "Solde de tokens",
                "Watch 批准": "Approuver sur l’Apple Watch",
                "iPhone 已配对": "iPhone jumelé",
                "任务详情": "Détails de la tâche",
                "动态配对二维码": "QR de jumelage dynamique",
                "发生错误": "Une erreur est survenue",
                "发送": "Envoyer",
                "发送指令": "Envoyer une instruction",
                "启动受控任务": "Démarrer la tâche contrôlée",
                "启动新任务": "Démarrer une nouvelle tâche",
                "告诉 Codex 接下来做什么": "Indiquez à Codex quoi faire ensuite",
                "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。": "Scannez ce code dans Connexions sur l’iPhone ou saisissez les six chiffres ci-dessus. Le QR se met à jour avec le code.",
                "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。": "Saisissez ce code dans Connexions sur l’iPhone. Une fois jumelé, son Apple Watch utilisera la même connexion.",
                "当前 ChatGPT 桌面端未启用 Quick Chat；标准新对话会进入 Work，已停止发送以避免消耗 Codex/Work 额度": "Quick Chat n’est pas activé dans ChatGPT de bureau ; un nouveau chat standard ouvrirait Work. Envoi arrêté pour préserver le quota Codex/Work",
                "批准 Codex：%@": "Approuver Codex : %@",
                "找不到 ChatGPT 发送按钮": "Bouton Envoyer de ChatGPT introuvable",
                "找不到 ChatGPT 消息输入框": "Champ de message ChatGPT introuvable",
                "无法在 ChatGPT 中打开目标任务": "Impossible d’ouvrir la tâche dans ChatGPT",
                "无法控制 ChatGPT 桌面端：%@": "Impossible de contrôler ChatGPT de bureau : %@",
                "无法连接 ChatGPT 桌面控制：%@": "Impossible de se connecter au contrôle ChatGPT de bureau : %@",
                "桌面控制仅在接通电源时启用": "Le contrôle du bureau est actif uniquement lorsque le Mac est branché",
                "正在恢复 ChatGPT 桌面接口": "Restauration de l’interface ChatGPT de bureau",
                "正在连接 ChatGPT，正在验证远程中继": "Connexion à ChatGPT et vérification du relais distant",
                "此 ChatGPT Chat 已绑定远程浏览器网关，Mac 本地桥接器不会把它送入 Work 或 Codex": "Ce Chat ChatGPT utilise la passerelle de navigateur distante ; le pont Mac ne l’enverra pas vers Work ou Codex",
                "没有桌面窗口正在管理这个任务": "Aucune fenêtre de bureau ne gère cette tâche",
                "目标任务中已有未发送的草稿，为避免覆盖已取消发送": "La tâche contient déjà un brouillon non envoyé ; l’envoi a été annulé pour éviter de l’écraser",
                "自动可信连接": "Connexion de confiance automatique",
                "让 Codex 做什么？": "Que doit faire Codex ?",
                "请先在 Google Chrome 登录 chatgpt.com，再从 iPhone 或 Apple Watch 发送 Chat": "Connectez-vous d’abord à chatgpt.com dans Google Chrome, puis envoyez le Chat depuis l’iPhone ou l’Apple Watch",
                "请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试": "Autorisez Agent Bridge dans Réglages Système > Confidentialité et sécurité > Accessibilité, puis réessayez",
                "还没有任务": "Aucune tâche pour le moment",
                "配对二维码已移至设置的设备连接中": "Le QR de jumelage se trouve maintenant dans Réglages › Connexions",
                "重置后，下一台 iPhone 扫码或输入验证码即可配对。": "Après la réinitialisation, le prochain iPhone pourra se jumeler en scannant le code ou en saisissant les six chiffres.",
                "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复": "Après la première connexion, cet iPhone est mémorisé et se reconnecte sans code",
            ]
        case .german:
            return [
                "%@，正在验证远程中继": "%@, Remote-Relay wird geprüft",
                "ChatGPT 桌面接口暂不可用，远程中继保持在线": "Die ChatGPT-Desktop-Schnittstelle ist nicht verfügbar; das Remote-Relay bleibt online",
                "ChatGPT 桌面控制协议错误：%@": "ChatGPT-Desktop-Steuerungsprotokollfehler: %@",
                "ChatGPT 桌面控制通道不可用": "Der ChatGPT-Desktop-Steuerkanal ist nicht verfügbar",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "Berechtigungsanfragen der aktuellen ChatGPT-Aufgabe werden mit iPhone und Apple Watch synchronisiert; die Entscheidung geht an die ursprüngliche Aufgabe zurück.",
                "ChatGPT 桌面端未运行": "ChatGPT Desktop läuft nicht",
                "Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com": "Chrome Chat Bridge ist nicht verbunden; lade die Erweiterung in Chrome und öffne chatgpt.com",
                "Codex 任务": "Codex-Aufgaben",
                "设备": "Geräte",
                "Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试": "Google Chrome läuft nicht; öffne Chrome, melde dich bei chatgpt.com an und versuche es erneut",
                "Mac 动态配对码（首次连接）": "Mac-Kopplungscode (erste Verbindung)",
                "Token 余额": "Token-Guthaben",
                "Watch 批准": "Auf der Watch genehmigen",
                "iPhone 已配对": "iPhone gekoppelt",
                "任务详情": "Aufgabendetails",
                "动态配对二维码": "Dynamischer Kopplungs-QR-Code",
                "发生错误": "Ein Fehler ist aufgetreten",
                "发送": "Senden",
                "发送指令": "Anweisung senden",
                "启动受控任务": "Verwaltete Aufgabe starten",
                "启动新任务": "Neue Aufgabe starten",
                "告诉 Codex 接下来做什么": "Sag Codex, was als Nächstes zu tun ist",
                "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。": "Scanne diesen Code unter iPhone-Verbindungen oder gib die sechs Ziffern oben ein. Der QR-Code wird mit dem Code aktualisiert.",
                "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。": "Gib diesen Code unter iPhone-Verbindungen ein. Nach der Kopplung verwendet die Apple Watch dieselbe Verbindung.",
                "批准 Codex：%@": "Codex genehmigen: %@",
                "找不到 ChatGPT 发送按钮": "ChatGPT-Senden-Schaltfläche nicht gefunden",
                "找不到 ChatGPT 消息输入框": "ChatGPT-Nachrichtenfeld nicht gefunden",
                "无法在 ChatGPT 中打开目标任务": "Die Aufgabe konnte in ChatGPT nicht geöffnet werden",
                "无法控制 ChatGPT 桌面端：%@": "ChatGPT Desktop konnte nicht gesteuert werden: %@",
                "无法连接 ChatGPT 桌面控制：%@": "Keine Verbindung zur ChatGPT-Desktopsteuerung: %@",
                "桌面控制仅在接通电源时启用": "Desktopsteuerung ist nur bei angeschlossenem Mac aktiv",
                "正在恢复 ChatGPT 桌面接口": "ChatGPT-Desktop-Schnittstelle wird wiederhergestellt",
                "正在连接 ChatGPT，正在验证远程中继": "Verbindung zu ChatGPT und Prüfung des Remote-Relays",
                "没有桌面窗口正在管理这个任务": "Kein Desktopfenster verwaltet diese Aufgabe",
                "自动可信连接": "Automatische vertrauenswürdige Verbindung",
                "让 Codex 做什么？": "Was soll Codex tun?",
                "请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试": "Erlaube Agent Bridge unter Systemeinstellungen > Datenschutz & Sicherheit > Bedienungshilfen und versuche es erneut",
                "还没有任务": "Noch keine Aufgaben",
                "配对二维码已移至设置的设备连接中": "Der Kopplungs-QR-Code befindet sich jetzt unter Einstellungen › Verbindungen",
                "重置后，下一台 iPhone 扫码或输入验证码即可配对。": "Nach dem Zurücksetzen kann das nächste iPhone durch Scannen oder Eingabe des sechsstelligen Codes gekoppelt werden.",
                "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复": "Nach der ersten Verbindung wird dieses iPhone gespeichert und stellt die Verbindung ohne Code wieder her",
            ]
        case .japanese:
            return [
                "%@，正在验证远程中继": "%@、リモートリレーを確認中",
                "ChatGPT 桌面接口暂不可用，远程中继保持在线": "ChatGPT デスクトップインターフェースは利用できません。リモートリレーはオンラインです",
                "ChatGPT 桌面控制协议错误：%@": "ChatGPT デスクトップ制御プロトコルエラー: %@",
                "ChatGPT 桌面控制通道不可用": "ChatGPT デスクトップ制御チャンネルを利用できません",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "現在の ChatGPT タスクの権限要求を iPhone と Apple Watch に同期し、決定を元のタスクへ返します。",
                "ChatGPT 桌面端未运行": "ChatGPT デスクトップは起動していません",
                "Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com": "Chrome Chat Bridge は未接続です。Chrome で拡張機能を読み込み chatgpt.com を開いてください",
                "Codex 任务": "Codex タスク",
                "设备": "デバイス",
                "Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试": "Google Chrome が起動していません。Chrome を開き chatgpt.com にログインして再試行してください",
                "Mac 动态配对码（首次连接）": "Mac ペアリングコード（初回接続）",
                "Token 余额": "トークン残高",
                "Watch 批准": "Watch で承認",
                "iPhone 已配对": "iPhone はペアリング済み",
                "任务详情": "タスクの詳細",
                "动态配对二维码": "動的ペアリング QR コード",
                "发生错误": "エラーが発生しました",
                "发送": "送信",
                "发送指令": "指示を送信",
                "启动受控任务": "管理タスクを開始",
                "启动新任务": "新しいタスクを開始",
                "告诉 Codex 接下来做什么": "次にすることを Codex に伝える",
                "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。": "iPhone の接続画面でこのコードをスキャンするか、上の 6 桁を入力してください。QR はコードに合わせて更新されます。",
                "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。": "iPhone の接続画面にこのコードを入力してください。ペアリング後、Apple Watch も同じ接続を使います。",
                "批准 Codex：%@": "Codex を承認: %@",
                "找不到 ChatGPT 发送按钮": "ChatGPT の送信ボタンが見つかりません",
                "找不到 ChatGPT 消息输入框": "ChatGPT の入力欄が見つかりません",
                "无法在 ChatGPT 中打开目标任务": "ChatGPT で対象タスクを開けませんでした",
                "无法控制 ChatGPT 桌面端：%@": "ChatGPT デスクトップを制御できません: %@",
                "无法连接 ChatGPT 桌面控制：%@": "ChatGPT デスクトップ制御に接続できません: %@",
                "桌面控制仅在接通电源时启用": "デスクトップ制御は Mac の電源接続中のみ有効です",
                "正在恢复 ChatGPT 桌面接口": "ChatGPT デスクトップインターフェースを復旧中",
                "正在连接 ChatGPT，正在验证远程中继": "ChatGPT に接続し、リモートリレーを確認中",
                "没有桌面窗口正在管理这个任务": "このタスクを管理しているデスクトップウィンドウがありません",
                "自动可信连接": "自動信頼接続",
                "让 Codex 做什么？": "Codex に何をさせますか？",
                "请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试": "システム設定 > プライバシーとセキュリティ > アクセシビリティで Agent Bridge を許可して再試行してください",
                "还没有任务": "タスクはまだありません",
                "配对二维码已移至设置的设备连接中": "ペアリング QR は設定 › 接続に移動しました",
                "重置后，下一台 iPhone 扫码或输入验证码即可配对。": "リセット後は、次の iPhone でスキャンするか 6 桁のコードを入力してペアリングできます。",
                "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复": "初回接続後は iPhone を記憶し、切断後もコードなしで復旧します",
            ]
        case .korean:
            return [
                "%@，正在验证远程中继": "%@, 원격 릴레이 확인 중",
                "ChatGPT 桌面接口暂不可用，远程中继保持在线": "ChatGPT 데스크톱 인터페이스를 사용할 수 없습니다. 원격 릴레이는 온라인입니다",
                "ChatGPT 桌面控制协议错误：%@": "ChatGPT 데스크톱 제어 프로토콜 오류: %@",
                "ChatGPT 桌面控制通道不可用": "ChatGPT 데스크톱 제어 채널을 사용할 수 없습니다",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "현재 ChatGPT 작업의 권한 요청을 iPhone 및 Apple Watch와 동기화하고 결정을 원래 작업으로 돌려보냅니다.",
                "ChatGPT 桌面端未运行": "ChatGPT 데스크톱이 실행 중이 아닙니다",
                "Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com": "Chrome Chat Bridge가 연결되지 않았습니다. Chrome에서 확장 프로그램을 불러오고 chatgpt.com을 여세요",
                "Codex 任务": "Codex 작업",
                "设备": "기기",
                "Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试": "Google Chrome이 실행 중이 아닙니다. Chrome을 열고 chatgpt.com에 로그인한 뒤 다시 시도하세요",
                "Mac 动态配对码（首次连接）": "Mac 페어링 코드(첫 연결)",
                "Token 余额": "토큰 잔액",
                "Watch 批准": "Watch에서 승인",
                "iPhone 已配对": "iPhone 페어링됨",
                "任务详情": "작업 세부사항",
                "动态配对二维码": "동적 페어링 QR 코드",
                "发生错误": "오류가 발생했습니다",
                "发送": "보내기",
                "发送指令": "지시 보내기",
                "启动受控任务": "관리 작업 시작",
                "启动新任务": "새 작업 시작",
                "告诉 Codex 接下来做什么": "Codex에게 다음 작업을 알려주세요",
                "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。": "iPhone 연결에서 이 코드를 스캔하거나 위의 6자리를 입력하세요. QR은 코드와 함께 업데이트됩니다.",
                "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。": "iPhone 연결에 이 코드를 입력하세요. 페어링되면 Apple Watch도 같은 연결을 사용합니다.",
                "批准 Codex：%@": "Codex 승인: %@",
                "找不到 ChatGPT 发送按钮": "ChatGPT 보내기 버튼을 찾을 수 없습니다",
                "找不到 ChatGPT 消息输入框": "ChatGPT 메시지 입력란을 찾을 수 없습니다",
                "无法在 ChatGPT 中打开目标任务": "ChatGPT에서 작업을 열 수 없습니다",
                "无法控制 ChatGPT 桌面端：%@": "ChatGPT 데스크톱을 제어할 수 없습니다: %@",
                "无法连接 ChatGPT 桌面控制：%@": "ChatGPT 데스크톱 제어에 연결할 수 없습니다: %@",
                "桌面控制仅在接通电源时启用": "데스크톱 제어는 Mac이 전원에 연결된 경우에만 활성화됩니다",
                "正在恢复 ChatGPT 桌面接口": "ChatGPT 데스크톱 인터페이스 복구 중",
                "正在连接 ChatGPT，正在验证远程中继": "ChatGPT에 연결하고 원격 릴레이를 확인하는 중",
                "没有桌面窗口正在管理这个任务": "이 작업을 관리하는 데스크톱 창이 없습니다",
                "自动可信连接": "자동 신뢰 연결",
                "让 Codex 做什么？": "Codex가 무엇을 할까요?",
                "请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试": "시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 Agent Bridge를 허용한 뒤 다시 시도하세요",
                "还没有任务": "아직 작업이 없습니다",
                "配对二维码已移至设置的设备连接中": "페어링 QR 코드는 이제 설정 › 연결에 있습니다",
                "重置后，下一台 iPhone 扫码或输入验证码即可配对。": "재설정 후 다음 iPhone은 스캔하거나 6자리 코드를 입력해 페어링할 수 있습니다.",
                "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复": "첫 연결 후 iPhone을 기억하며 연결이 끊겨도 코드 없이 복구합니다",
            ]
        case .portuguese:
            return [
                "%@，正在验证远程中继": "%@, verificando o relay remoto",
                "ChatGPT 桌面接口暂不可用，远程中继保持在线": "A interface do ChatGPT para desktop está indisponível; o relay remoto continua online",
                "ChatGPT 桌面控制协议错误：%@": "Erro de protocolo do controle do ChatGPT para desktop: %@",
                "ChatGPT 桌面控制通道不可用": "O canal de controle do ChatGPT para desktop está indisponível",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "As solicitações de permissão da tarefa atual do ChatGPT são sincronizadas com iPhone e Apple Watch; a decisão retorna à tarefa original.",
                "ChatGPT 桌面端未运行": "O ChatGPT para desktop não está em execução",
                "Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com": "O Chrome Chat Bridge não está conectado; carregue a extensão no Chrome e abra chatgpt.com",
                "Codex 任务": "Tarefas do Codex",
                "设备": "Dispositivos",
                "Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试": "O Google Chrome não está em execução; abra-o, entre em chatgpt.com e tente novamente",
                "Mac 动态配对码（首次连接）": "Código de pareamento do Mac (primeira conexão)",
                "Token 余额": "Saldo de tokens",
                "Watch 批准": "Aprovar no Watch",
                "iPhone 已配对": "iPhone pareado",
                "任务详情": "Detalhes da tarefa",
                "动态配对二维码": "QR de pareamento dinâmico",
                "发生错误": "Ocorreu um erro",
                "发送": "Enviar",
                "发送指令": "Enviar instrução",
                "启动受控任务": "Iniciar tarefa controlada",
                "启动新任务": "Iniciar nova tarefa",
                "告诉 Codex 接下来做什么": "Diga ao Codex o que fazer em seguida",
                "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。": "Escaneie este código em Conexões do iPhone ou digite os seis dígitos acima. O QR é atualizado com o código.",
                "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。": "Digite este código em Conexões do iPhone. Depois do pareamento, o Apple Watch usará a mesma conexão.",
                "批准 Codex：%@": "Aprovar Codex: %@",
                "找不到 ChatGPT 发送按钮": "Botão Enviar do ChatGPT não encontrado",
                "找不到 ChatGPT 消息输入框": "Campo de mensagem do ChatGPT não encontrado",
                "无法在 ChatGPT 中打开目标任务": "Não foi possível abrir a tarefa no ChatGPT",
                "无法控制 ChatGPT 桌面端：%@": "Não foi possível controlar o ChatGPT para desktop: %@",
                "无法连接 ChatGPT 桌面控制：%@": "Não foi possível conectar ao controle do ChatGPT para desktop: %@",
                "桌面控制仅在接通电源时启用": "O controle do desktop só funciona quando o Mac está conectado à energia",
                "正在恢复 ChatGPT 桌面接口": "Restaurando a interface do ChatGPT para desktop",
                "正在连接 ChatGPT，正在验证远程中继": "Conectando ao ChatGPT e verificando o relay remoto",
                "没有桌面窗口正在管理这个任务": "Nenhuma janela do desktop gerencia esta tarefa",
                "自动可信连接": "Conexão confiável automática",
                "让 Codex 做什么？": "O que o Codex deve fazer?",
                "请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试": "Permita o Agent Bridge em Ajustes do Sistema > Privacidade e Segurança > Acessibilidade e tente novamente",
                "还没有任务": "Ainda não há tarefas",
                "配对二维码已移至设置的设备连接中": "O QR de pareamento agora está em Ajustes › Conexões",
                "重置后，下一台 iPhone 扫码或输入验证码即可配对。": "Após redefinir, o próximo iPhone pode parear escaneando ou digitando o código de seis dígitos.",
                "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复": "Após a primeira conexão, este iPhone fica salvo e se recupera sem código após uma queda",
            ]
        case .italian:
            return [
                "%@，正在验证远程中继": "%@, verifica del relay remoto",
                "ChatGPT 桌面接口暂不可用，远程中继保持在线": "L’interfaccia desktop di ChatGPT non è disponibile; il relay remoto resta online",
                "ChatGPT 桌面控制协议错误：%@": "Errore del protocollo di controllo desktop ChatGPT: %@",
                "ChatGPT 桌面控制通道不可用": "Il canale di controllo desktop ChatGPT non è disponibile",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "Le richieste di autorizzazione dell’attività ChatGPT vengono sincronizzate con iPhone e Apple Watch; la decisione torna all’attività originale.",
                "ChatGPT 桌面端未运行": "ChatGPT desktop non è in esecuzione",
                "Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com": "Chrome Chat Bridge non è connesso; carica l’estensione in Chrome e apri chatgpt.com",
                "Codex 任务": "Attività Codex",
                "设备": "Dispositivi",
                "Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试": "Google Chrome non è in esecuzione; aprilo, accedi a chatgpt.com e riprova",
                "Mac 动态配对码（首次连接）": "Codice di abbinamento Mac (prima connessione)",
                "Token 余额": "Saldo token",
                "Watch 批准": "Approva su Watch",
                "iPhone 已配对": "iPhone abbinato",
                "任务详情": "Dettagli attività",
                "动态配对二维码": "Codice QR di abbinamento dinamico",
                "发生错误": "Si è verificato un errore",
                "发送": "Invia",
                "发送指令": "Invia istruzione",
                "启动受控任务": "Avvia attività gestita",
                "启动新任务": "Avvia nuova attività",
                "告诉 Codex 接下来做什么": "Dì a Codex cosa fare dopo",
                "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。": "Scansiona questo codice in Connessioni su iPhone oppure inserisci le sei cifre sopra. Il QR si aggiorna con il codice.",
                "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。": "Inserisci questo codice in Connessioni su iPhone. Dopo l’abbinamento, Apple Watch userà la stessa connessione.",
                "批准 Codex：%@": "Approva Codex: %@",
                "找不到 ChatGPT 发送按钮": "Pulsante Invia di ChatGPT non trovato",
                "找不到 ChatGPT 消息输入框": "Campo messaggio di ChatGPT non trovato",
                "无法在 ChatGPT 中打开目标任务": "Impossibile aprire l’attività in ChatGPT",
                "无法控制 ChatGPT 桌面端：%@": "Impossibile controllare ChatGPT desktop: %@",
                "无法连接 ChatGPT 桌面控制：%@": "Impossibile connettersi al controllo desktop ChatGPT: %@",
                "桌面控制仅在接通电源时启用": "Il controllo desktop è attivo solo quando il Mac è collegato all’alimentazione",
                "正在恢复 ChatGPT 桌面接口": "Ripristino dell’interfaccia ChatGPT desktop",
                "正在连接 ChatGPT，正在验证远程中继": "Connessione a ChatGPT e verifica del relay remoto",
                "没有桌面窗口正在管理这个任务": "Nessuna finestra desktop gestisce questa attività",
                "自动可信连接": "Connessione affidabile automatica",
                "让 Codex 做什么？": "Cosa deve fare Codex?",
                "请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试": "Consenti Agent Bridge in Impostazioni di Sistema > Privacy e sicurezza > Accessibilità, poi riprova",
                "还没有任务": "Nessuna attività ancora",
                "配对二维码已移至设置的设备连接中": "Il QR di abbinamento è ora in Impostazioni › Connessioni",
                "重置后，下一台 iPhone 扫码或输入验证码即可配对。": "Dopo il ripristino, il prossimo iPhone può abbinarsi scansionando o inserendo il codice a sei cifre.",
                "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复": "Dopo la prima connessione, questo iPhone viene ricordato e si ripristina senza codice",
            ]
        case .russian:
            return [
                "%@，正在验证远程中继": "%@, проверка удалённого ретранслятора",
                "ChatGPT 桌面接口暂不可用，远程中继保持在线": "Интерфейс ChatGPT для компьютера недоступен; удалённый ретранслятор в сети",
                "ChatGPT 桌面控制协议错误：%@": "Ошибка протокола управления ChatGPT для компьютера: %@",
                "ChatGPT 桌面控制通道不可用": "Канал управления ChatGPT для компьютера недоступен",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "Запросы разрешений текущей задачи ChatGPT синхронизируются с iPhone и Apple Watch; решение возвращается исходной задаче.",
                "ChatGPT 桌面端未运行": "ChatGPT для компьютера не запущен",
                "Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com": "Chrome Chat Bridge не подключён; загрузите расширение в Chrome и откройте chatgpt.com",
                "Codex 任务": "Задачи Codex",
                "设备": "Устройства",
                "Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试": "Google Chrome не запущен; откройте его, войдите на chatgpt.com и повторите попытку",
                "Mac 动态配对码（首次连接）": "Код сопряжения Mac (первое подключение)",
                "Token 余额": "Баланс токенов",
                "Watch 批准": "Одобрить на Watch",
                "iPhone 已配对": "iPhone сопряжён",
                "任务详情": "Сведения о задаче",
                "动态配对二维码": "Динамический QR-код сопряжения",
                "发生错误": "Произошла ошибка",
                "发送": "Отправить",
                "发送指令": "Отправить инструкцию",
                "启动受控任务": "Запустить управляемую задачу",
                "启动新任务": "Запустить новую задачу",
                "告诉 Codex 接下来做什么": "Укажите Codex, что делать дальше",
                "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。": "Отсканируйте код в разделе подключений iPhone или введите шесть цифр выше. QR-код обновляется вместе с кодом.",
                "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。": "Введите код в разделе подключений iPhone. После сопряжения Apple Watch будет использовать то же соединение.",
                "批准 Codex：%@": "Одобрить Codex: %@",
                "找不到 ChatGPT 发送按钮": "Не найдена кнопка отправки ChatGPT",
                "找不到 ChatGPT 消息输入框": "Не найдено поле сообщения ChatGPT",
                "无法在 ChatGPT 中打开目标任务": "Не удалось открыть задачу в ChatGPT",
                "无法控制 ChatGPT 桌面端：%@": "Не удалось управлять ChatGPT для компьютера: %@",
                "无法连接 ChatGPT 桌面控制：%@": "Не удалось подключиться к управлению ChatGPT для компьютера: %@",
                "桌面控制仅在接通电源时启用": "Управление компьютером доступно только при подключённом питании Mac",
                "正在恢复 ChatGPT 桌面接口": "Восстановление интерфейса ChatGPT для компьютера",
                "正在连接 ChatGPT，正在验证远程中继": "Подключение к ChatGPT и проверка удалённого ретранслятора",
                "没有桌面窗口正在管理这个任务": "Нет окна компьютера, управляющего этой задачей",
                "自动可信连接": "Автоматическое доверенное подключение",
                "让 Codex 做什么？": "Что должен сделать Codex?",
                "请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试": "Разрешите Agent Bridge в Системных настройках > Конфиденциальность и безопасность > Универсальный доступ и повторите попытку",
                "还没有任务": "Задач пока нет",
                "配对二维码已移至设置的设备连接中": "QR-код сопряжения теперь находится в Настройках › Подключения",
                "重置后，下一台 iPhone 扫码或输入验证码即可配对。": "После сброса следующий iPhone можно сопрячь сканированием или вводом шестизначного кода.",
                "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复": "После первого подключения этот iPhone запоминается и восстанавливается без кода",
            ]
        case .arabic:
            return [
                "%@，正在验证远程中继": "%@، جارٍ التحقق من الترحيل البعيد",
                "ChatGPT 桌面接口暂不可用，远程中继保持在线": "واجهة ChatGPT لسطح المكتب غير متاحة؛ الترحيل البعيد متصل",
                "ChatGPT 桌面控制协议错误：%@": "خطأ في بروتوكول التحكم بسطح مكتب ChatGPT: %@",
                "ChatGPT 桌面控制通道不可用": "قناة التحكم بسطح مكتب ChatGPT غير متاحة",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "تتم مزامنة طلبات أذونات مهمة ChatGPT الحالية مع iPhone وApple Watch، ويعود القرار إلى المهمة الأصلية.",
                "ChatGPT 桌面端未运行": "ChatGPT لسطح المكتب غير قيد التشغيل",
                "Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com": "لم يتصل Chrome Chat Bridge؛ حمّل الإضافة في Chrome وافتح chatgpt.com",
                "Codex 任务": "مهام Codex",
                "设备": "الأجهزة",
                "Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试": "Google Chrome غير قيد التشغيل؛ افتحه وسجّل الدخول إلى chatgpt.com ثم أعد المحاولة",
                "Mac 动态配对码（首次连接）": "رمز اقتران Mac (الاتصال الأول)",
                "Token 余额": "رصيد الرموز",
                "Watch 批准": "الموافقة على Watch",
                "iPhone 已配对": "تم إقران iPhone",
                "任务详情": "تفاصيل المهمة",
                "动态配对二维码": "رمز QR للاقتران الديناميكي",
                "发生错误": "حدث خطأ",
                "发送": "إرسال",
                "发送指令": "إرسال التعليمات",
                "启动受控任务": "بدء مهمة مُدارة",
                "启动新任务": "بدء مهمة جديدة",
                "告诉 Codex 接下来做什么": "أخبر Codex بما يفعله بعد ذلك",
                "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。": "امسح هذا الرمز في اتصالات iPhone أو أدخل الأرقام الستة أعلاه. يتحدّث QR مع الرمز.",
                "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。": "أدخل هذا الرمز في اتصالات iPhone. بعد الاقتران سيستخدم Apple Watch الاتصال نفسه.",
                "批准 Codex：%@": "الموافقة على Codex: %@",
                "找不到 ChatGPT 发送按钮": "تعذّر العثور على زر إرسال ChatGPT",
                "找不到 ChatGPT 消息输入框": "تعذّر العثور على حقل رسالة ChatGPT",
                "无法在 ChatGPT 中打开目标任务": "تعذّر فتح المهمة في ChatGPT",
                "无法控制 ChatGPT 桌面端：%@": "تعذّر التحكم في ChatGPT لسطح المكتب: %@",
                "无法连接 ChatGPT 桌面控制：%@": "تعذّر الاتصال بالتحكم في ChatGPT لسطح المكتب: %@",
                "桌面控制仅在接通电源时启用": "يتوفر التحكم بسطح المكتب فقط عند توصيل Mac بالطاقة",
                "正在恢复 ChatGPT 桌面接口": "جارٍ استعادة واجهة ChatGPT لسطح المكتب",
                "正在连接 ChatGPT，正在验证远程中继": "جارٍ الاتصال بـ ChatGPT والتحقق من الترحيل البعيد",
                "没有桌面窗口正在管理这个任务": "لا توجد نافذة سطح مكتب تدير هذه المهمة",
                "自动可信连接": "اتصال موثوق تلقائي",
                "让 Codex 做什么？": "ماذا يفعل Codex؟",
                "请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试": "اسمح لـ Agent Bridge في إعدادات النظام > الخصوصية والأمان > تسهيلات الاستخدام ثم أعد المحاولة",
                "还没有任务": "لا توجد مهام بعد",
                "配对二维码已移至设置的设备连接中": "يوجد QR للاقتران الآن في الإعدادات › الاتصالات",
                "重置后，下一台 iPhone 扫码或输入验证码即可配对。": "بعد إعادة الضبط يمكن إقران iPhone التالي بالمسح أو إدخال الرمز المكوّن من ستة أرقام.",
                "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复": "بعد الاتصال الأول سيتم تذكّر iPhone هذا واستعادته دون رمز عند انقطاعه",
            ]
        case .hindi:
            return [
                "%@，正在验证远程中继": "%@, रिमोट रिले सत्यापित हो रहा है",
                "ChatGPT 桌面接口暂不可用，远程中继保持在线": "ChatGPT डेस्कटॉप इंटरफ़ेस उपलब्ध नहीं है; रिमोट रिले ऑनलाइन है",
                "ChatGPT 桌面控制协议错误：%@": "ChatGPT डेस्कटॉप नियंत्रण प्रोटोकॉल त्रुटि: %@",
                "ChatGPT 桌面控制通道不可用": "ChatGPT डेस्कटॉप नियंत्रण चैनल उपलब्ध नहीं है",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "वर्तमान ChatGPT कार्य के अनुमति अनुरोध iPhone और Apple Watch से सिंक होते हैं; निर्णय मूल कार्य में लौटता है।",
                "ChatGPT 桌面端未运行": "ChatGPT डेस्कटॉप चल नहीं रहा है",
                "Chrome Chat Bridge 尚未连接；请在 Chrome 加载扩展并打开 chatgpt.com": "Chrome Chat Bridge कनेक्ट नहीं है; Chrome में एक्सटेंशन लोड करके chatgpt.com खोलें",
                "Codex 任务": "Codex कार्य",
                "设备": "डिवाइस",
                "Google Chrome 未运行；请打开 Chrome 并登录 chatgpt.com 后重试": "Google Chrome चल नहीं रहा है; इसे खोलकर chatgpt.com में साइन इन करें और फिर प्रयास करें",
                "Mac 动态配对码（首次连接）": "Mac पेयरिंग कोड (पहला कनेक्शन)",
                "Token 余额": "टोकन शेष",
                "Watch 批准": "Watch पर मंज़ूर करें",
                "iPhone 已配对": "iPhone पेयर हो गया",
                "任务详情": "कार्य विवरण",
                "动态配对二维码": "डायनेमिक पेयरिंग QR कोड",
                "发生错误": "एक त्रुटि हुई",
                "发送": "भेजें",
                "发送指令": "निर्देश भेजें",
                "启动受控任务": "प्रबंधित कार्य शुरू करें",
                "启动新任务": "नया कार्य शुरू करें",
                "告诉 Codex 接下来做什么": "Codex को अगला काम बताएँ",
                "在 iPhone 的设备连接中扫描此二维码，或输入上方六码。二维码会随验证码自动更新。": "iPhone कनेक्शन में इस कोड को स्कैन करें या ऊपर के छह अंक दर्ज करें। QR कोड के साथ अपडेट होता है।",
                "在 iPhone 的设备连接中输入此动态码。iPhone 配对成功后，其 Apple Watch 会自动取得同一连接。": "iPhone कनेक्शन में यह कोड दर्ज करें। पेयर होने के बाद Apple Watch भी यही कनेक्शन उपयोग करेगा।",
                "批准 Codex：%@": "Codex मंज़ूर करें: %@",
                "找不到 ChatGPT 发送按钮": "ChatGPT का भेजें बटन नहीं मिला",
                "找不到 ChatGPT 消息输入框": "ChatGPT संदेश फ़ील्ड नहीं मिला",
                "无法在 ChatGPT 中打开目标任务": "ChatGPT में कार्य नहीं खोला जा सका",
                "无法控制 ChatGPT 桌面端：%@": "ChatGPT डेस्कटॉप नियंत्रित नहीं किया जा सका: %@",
                "无法连接 ChatGPT 桌面控制：%@": "ChatGPT डेस्कटॉप नियंत्रण से कनेक्ट नहीं हो सका: %@",
                "桌面控制仅在接通电源时启用": "डेस्कटॉप नियंत्रण केवल Mac के पावर से जुड़े होने पर सक्रिय है",
                "正在恢复 ChatGPT 桌面接口": "ChatGPT डेस्कटॉप इंटरफ़ेस बहाल हो रहा है",
                "正在连接 ChatGPT，正在验证远程中继": "ChatGPT से कनेक्ट और रिमोट रिले सत्यापित हो रहा है",
                "没有桌面窗口正在管理这个任务": "इस कार्य को प्रबंधित करने वाली कोई डेस्कटॉप विंडो नहीं है",
                "自动可信连接": "स्वचालित विश्वसनीय कनेक्शन",
                "让 Codex 做什么？": "Codex क्या करे?",
                "请在系统设置 > 隐私与安全性 > 辅助功能中允许 Agent Bridge，然后重试": "सिस्टम सेटिंग्स > गोपनीयता और सुरक्षा > एक्सेसिबिलिटी में Agent Bridge की अनुमति दें और फिर प्रयास करें",
                "还没有任务": "अभी कोई कार्य नहीं",
                "配对二维码已移至设置的设备连接中": "पेयरिंग QR अब सेटिंग्स › कनेक्शन में है",
                "重置后，下一台 iPhone 扫码或输入验证码即可配对。": "रीसेट के बाद अगला iPhone स्कैन करके या छह अंकों का कोड दर्ज करके पेयर हो सकता है।",
                "首次连接后记住这台 iPhone，无需验证码；断线后自动恢复": "पहले कनेक्शन के बाद यह iPhone याद रखा जाएगा और डिस्कनेक्ट होने पर बिना कोड के बहाल होगा",
            ]
        default:
            return [:]
        }
    }

    private static func common(for language: AppLanguage) -> [String: String] {
        switch language {
        case .spanish:
            return [
                "自动重连与离线队列始终开启": "La reconexión automática y la entrega sin conexión están siempre activas",
                "审批同步": "Sincronización de aprobaciones",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "Las solicitudes del ChatGPT de escritorio se sincronizan con iPhone y Apple Watch; las decisiones vuelven a la tarea original.",
                "实时活动": "Actividades en vivo", "实时活动已开启": "Las actividades en vivo están activas", "实时活动已关闭": "Las actividades en vivo están desactivadas",
                "点右上角的新对话开始。": "Toca Nuevo chat en la esquina superior derecha para empezar.",
                "有运行中任务时，会优先推荐到 iPhone 锁屏和 Apple Watch 智能叠放。": "Las tareas activas se muestran primero en la pantalla bloqueada del iPhone y en la pila inteligente del Apple Watch.",
                "运行命令": "Ejecutar comando", "修改文件": "Modificar archivos", "请求权限": "Solicitar permiso", "需要确认": "Se requiere confirmación",
                "Codex 希望运行一条命令": "Codex quiere ejecutar un comando", "Codex 希望应用文件更改": "Codex quiere aplicar cambios de archivos", "Codex 希望扩大本次任务的访问范围": "Codex quiere un acceso más amplio para esta tarea", "Codex 正在等待确认": "Codex espera confirmación", "ChatGPT 希望使用一个外部工具": "ChatGPT quiere usar una herramienta externa", "网络访问": "Acceso de red"
            ]
        case .french:
            return [
                "自动重连与离线队列始终开启": "La reconnexion automatique et la livraison hors ligne sont toujours activées",
                "审批同步": "Synchronisation des approbations",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "Les demandes du ChatGPT de bureau sont synchronisées avec l’iPhone et l’Apple Watch ; les décisions reviennent à la tâche d’origine.",
                "实时活动": "Activités en direct", "实时活动已开启": "Les activités en direct sont activées", "实时活动已关闭": "Les activités en direct sont désactivées",
                "点右上角的新对话开始。": "Touchez Nouvelle discussion en haut à droite pour commencer.",
                "有运行中任务时，会优先推荐到 iPhone 锁屏和 Apple Watch 智能叠放。": "Les tâches en cours sont prioritaires sur l’écran verrouillé de l’iPhone et dans la pile intelligente de l’Apple Watch.",
                "运行命令": "Exécuter une commande", "修改文件": "Modifier des fichiers", "请求权限": "Demander l’autorisation", "需要确认": "Confirmation requise",
                "Codex 希望运行一条命令": "Codex veut exécuter une commande", "Codex 希望应用文件更改": "Codex veut appliquer des modifications de fichiers", "Codex 希望扩大本次任务的访问范围": "Codex veut un accès plus large pour cette tâche", "Codex 正在等待确认": "Codex attend une confirmation", "ChatGPT 希望使用一个外部工具": "ChatGPT souhaite utiliser un outil externe", "网络访问": "Accès réseau"
            ]
        case .german:
            return [
                "自动重连与离线队列始终开启": "Automatische Verbindung und Offline-Zustellung sind immer aktiv",
                "审批同步": "Genehmigungssynchronisierung",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "Berechtigungsanfragen aus ChatGPT für den Desktop werden mit iPhone und Apple Watch synchronisiert; Entscheidungen gehen an die ursprüngliche Aufgabe zurück.",
                "实时活动": "Live-Aktivitäten", "实时活动已开启": "Live-Aktivitäten sind aktiviert", "实时活动已关闭": "Live-Aktivitäten sind deaktiviert",
                "点右上角的新对话开始。": "Tippe oben rechts auf Neuer Chat, um zu beginnen.",
                "有运行中任务时，会优先推荐到 iPhone 锁屏和 Apple Watch 智能叠放。": "Laufende Aufgaben werden auf dem Sperrbildschirm des iPhone und im Smart-Stapel der Apple Watch bevorzugt angezeigt.",
                "运行命令": "Befehl ausführen", "修改文件": "Dateien ändern", "请求权限": "Zugriff anfordern", "需要确认": "Bestätigung erforderlich",
                "Codex 希望运行一条命令": "Codex möchte einen Befehl ausführen", "Codex 希望应用文件更改": "Codex möchte Dateiänderungen anwenden", "Codex 希望扩大本次任务的访问范围": "Codex möchte einen erweiterten Zugriff für diese Aufgabe", "Codex 正在等待确认": "Codex wartet auf Bestätigung", "ChatGPT 希望使用一个外部工具": "ChatGPT möchte ein externes Tool verwenden", "网络访问": "Netzwerkzugriff"
            ]
        case .japanese:
            return [
                "自动重连与离线队列始终开启": "自動再接続とオフライン配信は常に有効です",
                "审批同步": "承認の同期",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "デスクトップ版 ChatGPT の権限リクエストを iPhone と Apple Watch に同期し、決定を元のタスクへ返します。",
                "实时活动": "ライブアクティビティ", "实时活动已开启": "ライブアクティビティはオンです", "实时活动已关闭": "ライブアクティビティはオフです",
                "点右上角的新对话开始。": "右上の「新しいチャット」をタップして開始します。",
                "有运行中任务时，会优先推荐到 iPhone 锁屏和 Apple Watch 智能叠放。": "実行中のタスクは iPhone のロック画面と Apple Watch のスマートスタックに優先表示されます。",
                "运行命令": "コマンドを実行", "修改文件": "ファイルを変更", "请求权限": "権限をリクエスト", "需要确认": "確認が必要",
                "Codex 希望运行一条命令": "Codex はコマンドの実行を求めています", "Codex 希望应用文件更改": "Codex はファイル変更の適用を求めています", "Codex 希望扩大本次任务的访问范围": "Codex はこのタスクへの追加アクセスを求めています", "Codex 正在等待确认": "Codex は確認を待っています", "ChatGPT 希望使用一个外部工具": "ChatGPT は外部ツールの使用を求めています", "网络访问": "ネットワークアクセス"
            ]
        case .korean:
            return [
                "自动重连与离线队列始终开启": "자동 재연결 및 오프라인 전송은 항상 켜져 있습니다",
                "审批同步": "승인 동기화",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "데스크톱 ChatGPT의 권한 요청을 iPhone과 Apple Watch에 동기화하고 결정을 원래 작업으로 돌려보냅니다.",
                "实时活动": "실시간 현황", "实时活动已开启": "실시간 현황 켜짐", "实时活动已关闭": "실시간 현황 꺼짐",
                "点右上角的新对话开始。": "오른쪽 상단의 새 채팅을 눌러 시작하세요.",
                "有运行中任务时，会优先推荐到 iPhone 锁屏和 Apple Watch 智能叠放。": "실행 중인 작업은 iPhone 잠금 화면과 Apple Watch 스마트 스택에 우선 표시됩니다.",
                "运行命令": "명령 실행", "修改文件": "파일 수정", "请求权限": "권한 요청", "需要确认": "확인 필요",
                "Codex 希望运行一条命令": "Codex가 명령 실행을 요청함", "Codex 希望应用文件更改": "Codex가 파일 변경 적용을 요청함", "Codex 希望扩大本次任务的访问范围": "Codex가 이 작업에 대한 추가 접근을 요청함", "Codex 正在等待确认": "Codex가 확인을 기다리는 중", "ChatGPT 希望使用一个外部工具": "ChatGPT가 외부 도구 사용을 요청함", "网络访问": "네트워크 접근"
            ]
        case .portuguese:
            return [
                "自动重连与离线队列始终开启": "A reconexão automática e a entrega offline estão sempre ativas",
                "审批同步": "Sincronização de aprovações",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "As solicitações do ChatGPT para desktop são sincronizadas com iPhone e Apple Watch; as decisões retornam à tarefa original.",
                "实时活动": "Atividades ao vivo", "实时活动已开启": "Atividades ao vivo ativadas", "实时活动已关闭": "Atividades ao vivo desativadas",
                "点右上角的新对话开始。": "Toque em Nova conversa no canto superior direito para começar.",
                "有运行中任务时，会优先推荐到 iPhone 锁屏和 Apple Watch 智能叠放。": "As tarefas em execução aparecem primeiro na tela bloqueada do iPhone e na Pilha Inteligente do Apple Watch.",
                "运行命令": "Executar comando", "修改文件": "Modificar arquivos", "请求权限": "Solicitar permissão", "需要确认": "Confirmação necessária",
                "Codex 希望运行一条命令": "O Codex quer executar um comando", "Codex 希望应用文件更改": "O Codex quer aplicar alterações de arquivos", "Codex 希望扩大本次任务的访问范围": "O Codex quer acesso mais amplo para esta tarefa", "Codex 正在等待确认": "O Codex aguarda confirmação", "ChatGPT 希望使用一个外部工具": "O ChatGPT quer usar uma ferramenta externa", "网络访问": "Acesso à rede"
            ]
        case .italian:
            return [
                "自动重连与离线队列始终开启": "La riconnessione automatica e la consegna offline sono sempre attive",
                "审批同步": "Sincronizzazione approvazioni",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "Le richieste di ChatGPT per desktop vengono sincronizzate con iPhone e Apple Watch; le decisioni tornano all’attività originale.",
                "实时活动": "Attività live", "实时活动已开启": "Attività live attive", "实时活动已关闭": "Attività live disattivate",
                "点右上角的新对话开始。": "Tocca Nuova chat in alto a destra per iniziare.",
                "有运行中任务时，会优先推荐到 iPhone 锁屏和 Apple Watch 智能叠放。": "Le attività in esecuzione sono prioritarie nella schermata di blocco di iPhone e nella pila intelligente di Apple Watch.",
                "运行命令": "Esegui comando", "修改文件": "Modifica file", "请求权限": "Richiedi autorizzazione", "需要确认": "Conferma richiesta",
                "Codex 希望运行一条命令": "Codex vuole eseguire un comando", "Codex 希望应用文件更改": "Codex vuole applicare modifiche ai file", "Codex 希望扩大本次任务的访问范围": "Codex vuole un accesso più ampio per questa attività", "Codex 正在等待确认": "Codex attende conferma", "ChatGPT 希望使用一个外部工具": "ChatGPT vuole usare uno strumento esterno", "网络访问": "Accesso alla rete"
            ]
        case .russian:
            return [
                "自动重连与离线队列始终开启": "Автоподключение и доставка офлайн всегда включены",
                "审批同步": "Синхронизация подтверждений",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "Запросы разрешений ChatGPT для компьютера синхронизируются с iPhone и Apple Watch; решения возвращаются исходной задаче.",
                "实时活动": "Текущие действия", "实时活动已开启": "Текущие действия включены", "实时活动已关闭": "Текущие действия выключены",
                "点右上角的新对话开始。": "Нажмите «Новый чат» в правом верхнем углу, чтобы начать.",
                "有运行中任务时，会优先推荐到 iPhone 锁屏和 Apple Watch 智能叠放。": "Активные задачи показываются на экране блокировки iPhone и в смарт-стеке Apple Watch.",
                "运行命令": "Выполнить команду", "修改文件": "Изменить файлы", "请求权限": "Запросить доступ", "需要确认": "Требуется подтверждение",
                "Codex 希望运行一条命令": "Codex хочет выполнить команду", "Codex 希望应用文件更改": "Codex хочет применить изменения файлов", "Codex 希望扩大本次任务的访问范围": "Codex хочет расширенный доступ для этой задачи", "Codex 正在等待确认": "Codex ожидает подтверждения", "ChatGPT 希望使用一个外部工具": "ChatGPT хочет использовать внешний инструмент", "网络访问": "Доступ к сети"
            ]
        case .arabic:
            return [
                "自动重连与离线队列始终开启": "إعادة الاتصال التلقائي والتسليم دون اتصال مفعّلان دائماً",
                "审批同步": "مزامنة الموافقات",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "تتم مزامنة طلبات الأذونات من ChatGPT لسطح المكتب مع iPhone وApple Watch، وتعود القرارات إلى المهمة الأصلية.",
                "实时活动": "الأنشطة المباشرة", "实时活动已开启": "الأنشطة المباشرة مفعّلة", "实时活动已关闭": "الأنشطة المباشرة متوقفة",
                "点右上角的新对话开始。": "اضغط على دردشة جديدة في أعلى اليمين للبدء.",
                "有运行中任务时，会优先推荐到 iPhone 锁屏和 Apple Watch 智能叠放。": "تظهر المهام قيد التشغيل أولاً على شاشة قفل iPhone وفي المكدس الذكي على Apple Watch.",
                "运行命令": "تشغيل أمر", "修改文件": "تعديل الملفات", "请求权限": "طلب الإذن", "需要确认": "مطلوب التأكيد",
                "Codex 希望运行一条命令": "يريد Codex تشغيل أمر", "Codex 希望应用文件更改": "يريد Codex تطبيق تغييرات الملفات", "Codex 希望扩大本次任务的访问范围": "يريد Codex صلاحيات أوسع لهذه المهمة", "Codex 正在等待确认": "ينتظر Codex التأكيد", "ChatGPT 希望使用一个外部工具": "يريد ChatGPT استخدام أداة خارجية", "网络访问": "الوصول إلى الشبكة"
            ]
        case .hindi:
            return [
                "自动重连与离线队列始终开启": "स्वचालित पुनः कनेक्शन और ऑफ़लाइन डिलीवरी हमेशा चालू हैं",
                "审批同步": "अनुमोदन सिंक",
                "ChatGPT 桌面端当前任务的权限请求会同步到 iPhone 和 Apple Watch；审批决定会返回原任务。": "डेस्कटॉप ChatGPT के अनुमति अनुरोध iPhone और Apple Watch से सिंक होते हैं; निर्णय मूल कार्य को लौटते हैं।",
                "实时活动": "लाइव गतिविधियाँ", "实时活动已开启": "लाइव गतिविधियाँ चालू हैं", "实时活动已关闭": "लाइव गतिविधियाँ बंद हैं",
                "点右上角的新对话开始。": "शुरू करने के लिए ऊपर दाईं ओर नई चैट पर टैप करें।",
                "有运行中任务时，会优先推荐到 iPhone 锁屏和 Apple Watch 智能叠放।": "चल रहे कार्य iPhone लॉक स्क्रीन और Apple Watch स्मार्ट स्टैक में पहले दिखाए जाते हैं।",
                "运行命令": "कमांड चलाएँ", "修改文件": "फ़ाइलें संशोधित करें", "请求权限": "अनुमति का अनुरोध", "需要确认": "पुष्टि आवश्यक",
                "Codex 希望运行一条命令": "Codex कमांड चलाना चाहता है", "Codex 希望应用文件更改": "Codex फ़ाइल परिवर्तन लागू करना चाहता है", "Codex 希望扩大本次任务的访问范围": "Codex इस कार्य के लिए व्यापक पहुंच चाहता है", "Codex 正在等待确认": "Codex पुष्टि की प्रतीक्षा कर रहा है", "ChatGPT 希望使用一个外部工具": "ChatGPT बाहरी टूल का उपयोग करना चाहता है", "网络访问": "नेटवर्क पहुंच"
            ]
        default:
            return [:]
        }
    }

    private static let spanish: [String: String] = [
        "状态": "Estado", "审批": "Aprobaciones", "聊天": "Chats", "新对话": "Nuevo chat", "取消": "Cancelar", "设置": "Ajustes", "显示": "Pantalla", "语言": "Idioma", "跟随系统": "Seguir sistema", "简体中文": "Chino simplificado", "英语": "Inglés", "外观": "Apariencia", "浅色": "Claro", "深色": "Oscuro", "完成": "Listo",
        "Codex 控制": "Control de Codex", "Token 余额": "Saldo de tokens", "Token": "Token", "剩余": "Restante", "等待额度同步": "Esperando datos de uso", "额度与重置": "Uso y reinicio", "下次重置": "Próximo reinicio", "重置日期": "Fecha de reinicio", "重置卡": "Tarjetas de reinicio", "到期 %@": "Caduca %@", "无到期日": "Sin caducidad", "使用": "Usar", "确认": "Confirmar", "用量不可用": "Uso no disponible",
        "设备连接": "Conexiones", "手表": "Reloj", "远程在线": "Remoto conectado", "远程正在恢复": "Restableciendo conexión remota", "Mac 在线": "Mac conectado", "正在恢复": "Reconectando", "选择 Mac": "Elegir Mac", "正在搜索…": "Buscando…", "立即连接": "Conectar ahora", "正在连接…": "Conectando…", "配对 iPhone": "Enlazar iPhone", "配对或重新连接 iPhone": "Enlazar o reconectar iPhone", "自动保持连接": "Reconectar siempre",
        "最近任务": "Tareas recientes", "暂无受控任务": "Aún no hay tareas", "正在进行": "En curso", "运行中": "Ejecutando", "等待批准": "Esperando aprobación", "空闲": "Inactivo", "已完成": "Completado", "失败": "Fallido", "处理中": "Procesando", "刚刚": "ahora mismo",
        "处理审批": "Revisar aprobaciones", "待审批": "Aprobaciones pendientes", "全部处理完了": "Todo al día", "待处理": "Pendiente", "拒绝": "Denegar", "批准一次": "Permitir una vez", "命令": "Comando", "访问范围": "Alcance de acceso", "网络访问": "Acceso de red", "发生错误": "Algo salió mal", "未知错误": "Error desconocido", "提示": "Aviso",
        "ChatGPT 聊天": "Chat de ChatGPT", "新建 Codex": "Nuevo Codex", "发送": "Enviar", "输入消息": "Escribe un mensaje", "发一条消息": "Escribe un mensaje", "开始对话": "Iniciar chat", "对话": "Conversación", "任务详情": "Detalles de la tarea", "当前进度": "Progreso actual", "模型": "Modelo", "工作目录": "Directorio de trabajo", "继续对话": "Continuar conversación", "正在连接 ChatGPT…": "Conectando con ChatGPT…", "还没有对话": "Aún no hay chats",
        "在 iPhone 上确认 Codex：%@": "Confirma Codex en el iPhone: %@", "需要 Face ID 才能批准此请求": "Se requiere Face ID para aprobar esta solicitud", "iPhone 批准会先要求 Face ID": "La aprobación en iPhone solicitará Face ID primero", "佩戴手表并双击侧边按钮完成批准": "Ponte el Apple Watch y haz doble clic en el botón lateral para aprobar"
    ]

    private static let french: [String: String] = [
        "状态": "État", "审批": "Approbations", "聊天": "Discussions", "新对话": "Nouvelle discussion", "取消": "Annuler", "设置": "Réglages", "显示": "Affichage", "语言": "Langue", "跟随系统": "Suivre le système", "简体中文": "Chinois simplifié", "英语": "Anglais", "外观": "Apparence", "浅色": "Clair", "深色": "Sombre", "完成": "Terminé",
        "Codex 控制": "Contrôle Codex", "Token 余额": "Solde de tokens", "Token": "Token", "剩余": "Restant", "等待额度同步": "Synchronisation de l’utilisation…", "额度与重置": "Utilisation et réinitialisation", "下次重置": "Prochaine réinitialisation", "重置日期": "Date de réinitialisation", "重置卡": "Cartes de réinitialisation", "到期 %@": "Expire %@", "无到期日": "Sans expiration", "使用": "Utiliser", "确认": "Confirmer", "用量不可用": "Utilisation indisponible",
        "设备连接": "Connexions", "手表": "Watch", "远程在线": "Relais en ligne", "远程正在恢复": "Rétablissement du relais", "Mac 在线": "Mac en ligne", "正在恢复": "Reconnexion", "选择 Mac": "Choisir un Mac", "正在搜索…": "Recherche…", "立即连接": "Se connecter", "正在连接…": "Connexion…", "配对 iPhone": "Jumeler l’iPhone", "配对或重新连接 iPhone": "Jumeler ou reconnecter l’iPhone", "自动保持连接": "Toujours reconnecter",
        "最近任务": "Tâches récentes", "暂无受控任务": "Aucune tâche gérée", "正在进行": "En cours", "运行中": "En cours d’exécution", "等待批准": "En attente d’approbation", "空闲": "Inactif", "已完成": "Terminé", "失败": "Échec", "处理中": "Traitement", "刚刚": "à l’instant",
        "处理审批": "Examiner les approbations", "待审批": "Approbations en attente", "全部处理完了": "Tout est à jour", "待处理": "En attente", "拒绝": "Refuser", "批准一次": "Autoriser une fois", "命令": "Commande", "访问范围": "Portée d’accès", "网络访问": "Accès réseau", "发生错误": "Une erreur est survenue", "未知错误": "Erreur inconnue", "提示": "Info",
        "ChatGPT 聊天": "Discussion ChatGPT", "新建 Codex": "Nouveau Codex", "发送": "Envoyer", "输入消息": "Saisir un message", "发一条消息": "Saisir un message", "开始对话": "Commencer", "对话": "Conversation", "任务详情": "Détails de la tâche", "当前进度": "Progression actuelle", "模型": "Modèle", "工作目录": "Répertoire de travail", "继续对话": "Continuer la conversation", "正在连接 ChatGPT…": "Connexion à ChatGPT…", "还没有对话": "Aucune discussion",
        "在 iPhone 上确认 Codex：%@": "Confirmer Codex sur l’iPhone : %@", "需要 Face ID 才能批准此请求": "Face ID est requis pour approuver cette demande", "iPhone 批准会先要求 Face ID": "L’approbation sur iPhone demandera d’abord Face ID", "佩戴手表并双击侧边按钮完成批准": "Portez l’Apple Watch et double-cliquez sur le bouton latéral pour approuver"
    ]

    private static let german: [String: String] = [
        "状态": "Status", "审批": "Genehmigungen", "聊天": "Chats", "新对话": "Neuer Chat", "取消": "Abbrechen", "设置": "Einstellungen", "显示": "Anzeige", "语言": "Sprache", "跟随系统": "System folgen", "简体中文": "Vereinfachtes Chinesisch", "英语": "Englisch", "外观": "Darstellung", "浅色": "Hell", "深色": "Dunkel", "完成": "Fertig",
        "Codex 控制": "Codex-Steuerung", "Token 余额": "Token-Guthaben", "Token": "Token", "剩余": "Verbleibend", "等待额度同步": "Nutzungsdaten werden synchronisiert", "额度与重置": "Nutzung und Zurücksetzen", "下次重置": "Nächster Reset", "重置日期": "Reset-Datum", "重置卡": "Reset-Karten", "到期 %@": "Läuft ab %@", "无到期日": "Kein Ablaufdatum", "使用": "Verwenden", "确认": "Bestätigen", "用量不可用": "Nutzung nicht verfügbar",
        "设备连接": "Verbindungen", "手表": "Watch", "远程在线": "Relay online", "远程正在恢复": "Remote-Verbindung wird wiederhergestellt", "Mac 在线": "Mac online", "正在恢复": "Verbindung wird wiederhergestellt", "选择 Mac": "Mac auswählen", "正在搜索…": "Suche…", "立即连接": "Jetzt verbinden", "正在连接…": "Verbindung…", "配对 iPhone": "iPhone koppeln", "配对或重新连接 iPhone": "iPhone koppeln oder verbinden", "自动保持连接": "Immer automatisch verbinden",
        "最近任务": "Letzte Aufgaben", "暂无受控任务": "Noch keine verwalteten Aufgaben", "正在进行": "Aktiv", "运行中": "Wird ausgeführt", "等待批准": "Wartet auf Genehmigung", "空闲": "Inaktiv", "已完成": "Abgeschlossen", "失败": "Fehlgeschlagen", "处理中": "Wird verarbeitet", "刚刚": "gerade eben",
        "处理审批": "Genehmigungen prüfen", "待审批": "Ausstehende Genehmigungen", "全部处理完了": "Alles erledigt", "待处理": "Ausstehend", "拒绝": "Ablehnen", "批准一次": "Einmal erlauben", "命令": "Befehl", "访问范围": "Zugriffsbereich", "网络访问": "Netzwerkzugriff", "发生错误": "Etwas ist schiefgelaufen", "未知错误": "Unbekannter Fehler", "提示": "Hinweis",
        "ChatGPT 聊天": "ChatGPT-Chat", "新建 Codex": "Neuer Codex", "发送": "Senden", "输入消息": "Nachricht eingeben", "发一条消息": "Nachricht eingeben", "开始对话": "Chat starten", "对话": "Unterhaltung", "任务详情": "Aufgabendetails", "当前进度": "Aktueller Fortschritt", "模型": "Modell", "工作目录": "Arbeitsverzeichnis", "继续对话": "Unterhaltung fortsetzen", "正在连接 ChatGPT…": "Verbindung mit ChatGPT…", "还没有对话": "Noch keine Chats",
        "在 iPhone 上确认 Codex：%@": "Codex auf dem iPhone bestätigen: %@", "需要 Face ID 才能批准此请求": "Zum Genehmigen ist Face ID erforderlich", "iPhone 批准会先要求 Face ID": "Die iPhone-Genehmigung fordert zuerst Face ID an", "佩戴手表并双击侧边按钮完成批准": "Apple Watch anlegen und zum Genehmigen zweimal die Seitentaste drücken"
    ]

    private static let japanese: [String: String] = [
        "状态": "ステータス", "审批": "承認", "聊天": "チャット", "新对话": "新しいチャット", "取消": "キャンセル", "设置": "設定", "显示": "表示", "语言": "言語", "跟随系统": "システムに従う", "简体中文": "簡体字中国語", "英语": "英語", "外观": "外観", "浅色": "ライト", "深色": "ダーク", "完成": "完了",
        "Codex 控制": "Codex コントロール", "Token 余额": "トークン残高", "Token": "トークン", "剩余": "残り", "等待额度同步": "使用状況を同期中", "额度与重置": "使用量とリセット", "下次重置": "次回リセット", "重置日期": "リセット日", "重置卡": "リセットカード", "到期 %@": "%@ に期限切れ", "无到期日": "期限なし", "使用": "使用", "确认": "確認", "用量不可用": "使用量を取得できません",
        "设备连接": "接続", "手表": "Apple Watch", "远程在线": "リモート接続中", "远程正在恢复": "リモート接続を復旧中", "Mac 在线": "Mac オンライン", "正在恢复": "再接続中", "选择 Mac": "Mac を選択", "正在搜索…": "検索中…", "立即连接": "今すぐ接続", "正在连接…": "接続中…", "配对 iPhone": "iPhone をペアリング", "配对或重新连接 iPhone": "iPhone をペアリングまたは再接続", "自动保持连接": "常に再接続",
        "最近任务": "最近のタスク", "暂无受控任务": "管理中のタスクはありません", "正在进行": "進行中", "运行中": "実行中", "等待批准": "承認待ち", "空闲": "アイドル", "已完成": "完了", "失败": "失敗", "处理中": "処理中", "刚刚": "たった今",
        "处理审批": "承認を確認", "待审批": "保留中の承認", "全部处理完了": "すべて完了", "待处理": "保留中", "拒绝": "拒否", "批准一次": "一度だけ許可", "命令": "コマンド", "访问范围": "アクセス範囲", "网络访问": "ネットワークアクセス", "发生错误": "エラーが発生しました", "未知错误": "不明なエラー", "提示": "通知",
        "ChatGPT 聊天": "ChatGPT チャット", "新建 Codex": "新しい Codex", "发送": "送信", "输入消息": "メッセージを入力", "发一条消息": "メッセージを入力", "开始对话": "チャットを開始", "对话": "会話", "任务详情": "タスクの詳細", "当前进度": "現在の進捗", "模型": "モデル", "工作目录": "作業ディレクトリ", "继续对话": "会話を続ける", "正在连接 ChatGPT…": "ChatGPT に接続中…", "还没有对话": "チャットはまだありません",
        "在 iPhone 上确认 Codex：%@": "iPhone で Codex を確認: %@", "需要 Face ID 才能批准此请求": "このリクエストの承認には Face ID が必要です", "iPhone 批准会先要求 Face ID": "iPhone での承認には Face ID が必要です", "佩戴手表并双击侧边按钮完成批准": "Apple Watch を装着し、サイドボタンをダブルクリックして承認"
    ]

    private static let korean: [String: String] = [
        "状态": "상태", "审批": "승인", "聊天": "채팅", "新对话": "새 채팅", "取消": "취소", "设置": "설정", "显示": "화면", "语言": "언어", "跟随系统": "시스템 설정 따르기", "简体中文": "중국어 간체", "英语": "영어", "外观": "외관", "浅色": "라이트", "深色": "다크", "完成": "완료",
        "Codex 控制": "Codex 제어", "Token 余额": "토큰 잔액", "Token": "토큰", "剩余": "남음", "等待额度同步": "사용량 동기화 대기 중", "额度与重置": "사용량 및 재설정", "下次重置": "다음 재설정", "重置日期": "재설정 날짜", "重置卡": "재설정 카드", "到期 %@": "%@ 만료", "无到期日": "만료일 없음", "使用": "사용", "确认": "확인", "用量不可用": "사용량을 사용할 수 없음",
        "设备连接": "연결", "手表": "Apple Watch", "远程在线": "원격 온라인", "远程正在恢复": "원격 연결 복구 중", "Mac 在线": "Mac 온라인", "正在恢复": "재연결 중", "选择 Mac": "Mac 선택", "正在搜索…": "검색 중…", "立即连接": "지금 연결", "正在连接…": "연결 중…", "配对 iPhone": "iPhone 페어링", "配对或重新连接 iPhone": "iPhone 페어링 또는 재연결", "自动保持连接": "항상 재연결",
        "最近任务": "최근 작업", "暂无受控任务": "관리되는 작업이 없음", "正在进行": "진행 중", "运行中": "실행 중", "等待批准": "승인 대기 중", "空闲": "대기", "已完成": "완료됨", "失败": "실패", "处理中": "처리 중", "刚刚": "방금",
        "处理审批": "승인 검토", "待审批": "대기 중인 승인", "全部处理完了": "모두 처리됨", "待处理": "대기 중", "拒绝": "거부", "批准一次": "한 번 허용", "命令": "명령", "访问范围": "접근 범위", "网络访问": "네트워크 접근", "发生错误": "문제가 발생함", "未知错误": "알 수 없는 오류", "提示": "알림",
        "ChatGPT 聊天": "ChatGPT 채팅", "新建 Codex": "새 Codex", "发送": "보내기", "输入消息": "메시지 입력", "发一条消息": "메시지 입력", "开始对话": "채팅 시작", "对话": "대화", "任务详情": "작업 세부사항", "当前进度": "현재 진행률", "模型": "모델", "工作目录": "작업 디렉터리", "继续对话": "대화 계속하기", "正在连接 ChatGPT…": "ChatGPT 연결 중…", "还没有对话": "채팅이 아직 없음",
        "在 iPhone 上确认 Codex：%@": "iPhone에서 Codex 확인: %@", "需要 Face ID 才能批准此请求": "이 요청을 승인하려면 Face ID가 필요함", "iPhone 批准会先要求 Face ID": "iPhone 승인은 먼저 Face ID를 요청함", "佩戴手表并双击侧边按钮完成批准": "Apple Watch를 착용하고 측면 버튼을 두 번 눌러 승인"
    ]

    private static let portuguese: [String: String] = [
        "状态": "Status", "审批": "Aprovações", "聊天": "Conversas", "新对话": "Nova conversa", "取消": "Cancelar", "设置": "Ajustes", "显示": "Tela", "语言": "Idioma", "跟随系统": "Seguir o sistema", "简体中文": "Chinês simplificado", "英语": "Inglês", "外观": "Aparência", "浅色": "Claro", "深色": "Escuro", "完成": "Concluído",
        "Codex 控制": "Controle do Codex", "Token 余额": "Saldo de tokens", "Token": "Token", "剩余": "Restante", "等待额度同步": "Aguardando dados de uso", "额度与重置": "Uso e redefinição", "下次重置": "Próxima redefinição", "重置日期": "Data de redefinição", "重置卡": "Cartões de redefinição", "到期 %@": "Expira %@", "无到期日": "Sem validade", "使用": "Usar", "确认": "Confirmar", "用量不可用": "Uso indisponível",
        "设备连接": "Conexões", "手表": "Apple Watch", "远程在线": "Relay online", "远程正在恢复": "Restaurando conexão remota", "Mac 在线": "Mac online", "正在恢复": "Reconectando", "选择 Mac": "Escolher Mac", "正在搜索…": "Buscando…", "立即连接": "Conectar agora", "正在连接…": "Conectando…", "配对 iPhone": "Emparelhar iPhone", "配对或重新连接 iPhone": "Emparelhar ou reconectar iPhone", "自动保持连接": "Reconectar sempre",
        "最近任务": "Tarefas recentes", "暂无受控任务": "Nenhuma tarefa gerenciada", "正在进行": "Em andamento", "运行中": "Em execução", "等待批准": "Aguardando aprovação", "空闲": "Ocioso", "已完成": "Concluído", "失败": "Falhou", "处理中": "Processando", "刚刚": "agora mesmo",
        "处理审批": "Revisar aprovações", "待审批": "Aprovações pendentes", "全部处理完了": "Tudo em dia", "待处理": "Pendente", "拒绝": "Recusar", "批准一次": "Permitir uma vez", "命令": "Comando", "访问范围": "Escopo de acesso", "网络访问": "Acesso à rede", "发生错误": "Algo deu errado", "未知错误": "Erro desconhecido", "提示": "Aviso",
        "ChatGPT 聊天": "Chat do ChatGPT", "新建 Codex": "Novo Codex", "发送": "Enviar", "输入消息": "Digite uma mensagem", "发一条消息": "Digite uma mensagem", "开始对话": "Iniciar conversa", "对话": "Conversa", "任务详情": "Detalhes da tarefa", "当前进度": "Progresso atual", "模型": "Modelo", "工作目录": "Diretório de trabalho", "继续对话": "Continuar conversa", "正在连接 ChatGPT…": "Conectando ao ChatGPT…", "还没有对话": "Nenhuma conversa ainda",
        "在 iPhone 上确认 Codex：%@": "Confirmar Codex no iPhone: %@", "需要 Face ID 才能批准此请求": "Face ID é necessário para aprovar esta solicitação", "iPhone 批准会先要求 Face ID": "A aprovação no iPhone solicitará Face ID primeiro", "佩戴手表并双击侧边按钮完成批准": "Coloque o Apple Watch e clique duas vezes no botão lateral para aprovar"
    ]

    private static let italian: [String: String] = [
        "状态": "Stato", "审批": "Approvazioni", "聊天": "Chat", "新对话": "Nuova chat", "取消": "Annulla", "设置": "Impostazioni", "显示": "Schermo", "语言": "Lingua", "跟随系统": "Segui il sistema", "简体中文": "Cinese semplificato", "英语": "Inglese", "外观": "Aspetto", "浅色": "Chiaro", "深色": "Scuro", "完成": "Fine",
        "Codex 控制": "Controllo Codex", "Token 余额": "Saldo token", "Token": "Token", "剩余": "Rimanente", "等待额度同步": "In attesa dei dati di utilizzo", "额度与重置": "Utilizzo e reimpostazione", "下次重置": "Prossimo reset", "重置日期": "Data reset", "重置卡": "Schede di reset", "到期 %@": "Scade %@", "无到期日": "Nessuna scadenza", "使用": "Usa", "确认": "Conferma", "用量不可用": "Utilizzo non disponibile",
        "设备连接": "Connessioni", "手表": "Apple Watch", "远程在线": "Relay online", "远程正在恢复": "Ripristino del relay remoto", "Mac 在线": "Mac online", "正在恢复": "Riconnessione", "选择 Mac": "Scegli Mac", "正在搜索…": "Ricerca…", "立即连接": "Connetti ora", "正在连接…": "Connessione…", "配对 iPhone": "Abbina iPhone", "配对或重新连接 iPhone": "Abbina o riconnetti iPhone", "自动保持连接": "Riconnetti sempre",
        "最近任务": "Attività recenti", "暂无受控任务": "Nessuna attività gestita", "正在进行": "In corso", "运行中": "In esecuzione", "等待批准": "In attesa di approvazione", "空闲": "Inattivo", "已完成": "Completato", "失败": "Non riuscito", "处理中": "Elaborazione", "刚刚": "proprio ora",
        "处理审批": "Controlla approvazioni", "待审批": "Approvazioni in attesa", "全部处理完了": "Tutto aggiornato", "待处理": "In attesa", "拒绝": "Rifiuta", "批准一次": "Consenti una volta", "命令": "Comando", "访问范围": "Ambito di accesso", "网络访问": "Accesso alla rete", "发生错误": "Si è verificato un errore", "未知错误": "Errore sconosciuto", "提示": "Avviso",
        "ChatGPT 聊天": "Chat ChatGPT", "新建 Codex": "Nuovo Codex", "发送": "Invia", "输入消息": "Inserisci un messaggio", "发一条消息": "Inserisci un messaggio", "开始对话": "Inizia chat", "对话": "Conversazione", "任务详情": "Dettagli attività", "当前进度": "Progresso attuale", "模型": "Modello", "工作目录": "Directory di lavoro", "继续对话": "Continua conversazione", "正在连接 ChatGPT…": "Connessione a ChatGPT…", "还没有对话": "Nessuna chat",
        "在 iPhone 上确认 Codex：%@": "Conferma Codex su iPhone: %@", "需要 Face ID 才能批准此请求": "Face ID è richiesto per approvare questa richiesta", "iPhone 批准会先要求 Face ID": "L’approvazione su iPhone richiederà prima Face ID", "佩戴手表并双击侧边按钮完成批准": "Indossa Apple Watch e fai doppio clic sul tasto laterale per approvare"
    ]

    private static let russian: [String: String] = [
        "状态": "Статус", "审批": "Подтверждения", "聊天": "Чаты", "新对话": "Новый чат", "取消": "Отмена", "设置": "Настройки", "显示": "Экран", "语言": "Язык", "跟随系统": "Как в системе", "简体中文": "Упрощённый китайский", "英语": "Английский", "外观": "Оформление", "浅色": "Светлая", "深色": "Тёмная", "完成": "Готово",
        "Codex 控制": "Управление Codex", "Token 余额": "Баланс токенов", "Token": "Токены", "剩余": "Осталось", "等待额度同步": "Ожидание данных использования", "额度与重置": "Использование и сброс", "下次重置": "Следующий сброс", "重置日期": "Дата сброса", "重置卡": "Карты сброса", "到期 %@": "Истекает %@", "无到期日": "Без срока", "使用": "Использовать", "确认": "Подтвердить", "用量不可用": "Данные недоступны",
        "设备连接": "Подключения", "手表": "Apple Watch", "远程在线": "Удалённый relay подключён", "远程正在恢复": "Восстановление удалённого соединения", "Mac 在线": "Mac подключён", "正在恢复": "Переподключение", "选择 Mac": "Выбрать Mac", "正在搜索…": "Поиск…", "立即连接": "Подключиться", "正在连接…": "Подключение…", "配对 iPhone": "Связать iPhone", "配对或重新连接 iPhone": "Связать или подключить iPhone", "自动保持连接": "Всегда переподключаться",
        "最近任务": "Последние задачи", "暂无受控任务": "Управляемых задач пока нет", "正在进行": "Выполняется", "运行中": "Запущено", "等待批准": "Ожидает подтверждения", "空闲": "Ожидание", "已完成": "Завершено", "失败": "Ошибка", "处理中": "Обработка", "刚刚": "только что",
        "处理审批": "Проверить подтверждения", "待审批": "Ожидающие подтверждения", "全部处理完了": "Всё обработано", "待处理": "Ожидает", "拒绝": "Отклонить", "批准一次": "Разрешить один раз", "命令": "Команда", "访问范围": "Область доступа", "网络访问": "Доступ к сети", "发生错误": "Произошла ошибка", "未知错误": "Неизвестная ошибка", "提示": "Уведомление",
        "ChatGPT 聊天": "Чат ChatGPT", "新建 Codex": "Новый Codex", "发送": "Отправить", "输入消息": "Введите сообщение", "发一条消息": "Введите сообщение", "开始对话": "Начать чат", "对话": "Диалог", "任务详情": "Сведения о задаче", "当前进度": "Текущий прогресс", "模型": "Модель", "工作目录": "Рабочий каталог", "继续对话": "Продолжить диалог", "正在连接 ChatGPT…": "Подключение к ChatGPT…", "还没有对话": "Чатов пока нет",
        "在 iPhone 上确认 Codex：%@": "Подтвердите Codex на iPhone: %@", "需要 Face ID 才能批准此请求": "Для подтверждения нужен Face ID", "iPhone 批准会先要求 Face ID": "Подтверждение на iPhone сначала запросит Face ID", "佩戴手表并双击侧边按钮完成批准": "Наденьте Apple Watch и дважды нажмите боковую кнопку для подтверждения"
    ]

    private static let arabic: [String: String] = [
        "状态": "الحالة", "审批": "الموافقات", "聊天": "الدردشات", "新对话": "دردشة جديدة", "取消": "إلغاء", "设置": "الإعدادات", "显示": "العرض", "语言": "اللغة", "跟随系统": "اتباع النظام", "简体中文": "الصينية المبسطة", "英语": "الإنجليزية", "外观": "المظهر", "浅色": "فاتح", "深色": "داكن", "完成": "تم",
        "Codex 控制": "تحكم Codex", "Token 余额": "رصيد الرموز", "Token": "رموز", "剩余": "متبقٍ", "等待额度同步": "بانتظار بيانات الاستخدام", "额度与重置": "الاستخدام وإعادة التعيين", "下次重置": "إعادة التعيين التالية", "重置日期": "تاريخ إعادة التعيين", "重置卡": "بطاقات إعادة التعيين", "到期 %@": "تنتهي في %@", "无到期日": "بدون انتهاء", "使用": "استخدام", "确认": "تأكيد", "用量不可用": "الاستخدام غير متاح",
        "设备连接": "الاتصالات", "手表": "Apple Watch", "远程在线": "الترحيل البعيد متصل", "远程正在恢复": "استعادة الاتصال البعيد", "Mac 在线": "Mac متصل", "正在恢复": "إعادة الاتصال", "选择 Mac": "اختيار Mac", "正在搜索…": "جارٍ البحث…", "立即连接": "اتصال الآن", "正在连接…": "جارٍ الاتصال…", "配对 iPhone": "إقران iPhone", "配对或重新连接 iPhone": "إقران iPhone أو إعادة اتصاله", "自动保持连接": "إعادة الاتصال دائمًا",
        "最近任务": "المهام الأخيرة", "暂无受控任务": "لا توجد مهام مُدارة", "正在进行": "قيد التنفيذ", "运行中": "قيد التشغيل", "等待批准": "بانتظار الموافقة", "空闲": "خامل", "已完成": "مكتمل", "失败": "فشل", "处理中": "جارٍ المعالجة", "刚刚": "الآن",
        "处理审批": "مراجعة الموافقات", "待审批": "الموافقات المعلقة", "全部处理完了": "كل شيء محدث", "待处理": "معلق", "拒绝": "رفض", "批准一次": "السماح مرة واحدة", "命令": "الأمر", "访问范围": "نطاق الوصول", "网络访问": "الوصول إلى الشبكة", "发生错误": "حدث خطأ", "未知错误": "خطأ غير معروف", "提示": "تنبيه",
        "ChatGPT 聊天": "دردشة ChatGPT", "新建 Codex": "Codex جديد", "发送": "إرسال", "输入消息": "أدخل رسالة", "发一条消息": "أدخل رسالة", "开始对话": "بدء الدردشة", "对话": "المحادثة", "任务详情": "تفاصيل المهمة", "当前进度": "التقدم الحالي", "模型": "النموذج", "工作目录": "دليل العمل", "继续对话": "متابعة المحادثة", "正在连接 ChatGPT…": "جارٍ الاتصال بـ ChatGPT…", "还没有对话": "لا توجد دردشات بعد",
        "在 iPhone 上确认 Codex：%@": "تأكيد Codex على iPhone: %@", "需要 Face ID 才能批准此请求": "يلزم Face ID للموافقة على هذا الطلب", "iPhone 批准会先要求 Face ID": "ستطلب الموافقة على iPhone Face ID أولًا", "佩戴手表并双击侧边按钮完成批准": "ارتدِ Apple Watch واضغط مرتين على الزر الجانبي للموافقة"
    ]

    private static let hindi: [String: String] = [
        "状态": "स्थिति", "审批": "अनुमोदन", "聊天": "चैट", "新对话": "नई चैट", "取消": "रद्द करें", "设置": "सेटिंग्ज़", "显示": "प्रदर्शन", "语言": "भाषा", "跟随系统": "सिस्टम के अनुसार", "简体中文": "सरल चीनी", "英语": "अंग्रेज़ी", "外观": "रूप", "浅色": "हल्का", "深色": "गहरा", "完成": "पूर्ण",
        "Codex 控制": "Codex नियंत्रण", "Token 余额": "टोकन शेष", "Token": "टोकन", "剩余": "शेष", "等待额度同步": "उपयोग डेटा सिंक होने की प्रतीक्षा", "额度与重置": "उपयोग और रीसेट", "下次重置": "अगला रीसेट", "重置日期": "रीसेट की तारीख", "重置卡": "रीसेट कार्ड", "到期 %@": "%@ को समाप्त", "无到期日": "समाप्ति नहीं", "使用": "उपयोग करें", "确认": "पुष्टि करें", "用量不可用": "उपयोग उपलब्ध नहीं",
        "设备连接": "कनेक्शन", "手表": "Apple Watch", "远程在线": "रिमोट ऑनलाइन", "远程正在恢复": "रिमोट कनेक्शन बहाल हो रहा है", "Mac 在线": "Mac ऑनलाइन", "正在恢复": "पुनः कनेक्ट हो रहा है", "选择 Mac": "Mac चुनें", "正在搜索…": "खोज रहा है…", "立即连接": "अभी कनेक्ट करें", "正在连接…": "कनेक्ट हो रहा है…", "配对 iPhone": "iPhone पेयर करें", "配对或重新连接 iPhone": "iPhone पेयर या पुनः कनेक्ट करें", "自动保持连接": "हमेशा पुनः कनेक्ट करें",
        "最近任务": "हाल के कार्य", "暂无受控任务": "अभी कोई प्रबंधित कार्य नहीं", "正在进行": "चल रहा है", "运行中": "चल रहा है", "等待批准": "अनुमोदन की प्रतीक्षा", "空闲": "निष्क्रिय", "已完成": "पूर्ण", "失败": "विफल", "处理中": "प्रक्रिया में", "刚刚": "अभी",
        "处理审批": "अनुमोदन देखें", "待审批": "लंबित अनुमोदन", "全部处理完了": "सब अद्यतित", "待处理": "लंबित", "拒绝": "अस्वीकार", "批准一次": "एक बार अनुमति दें", "命令": "कमांड", "访问范围": "पहुंच का दायरा", "网络访问": "नेटवर्क पहुंच", "发生错误": "कुछ गलत हुआ", "未知错误": "अज्ञात त्रुटि", "提示": "सूचना",
        "ChatGPT 聊天": "ChatGPT चैट", "新建 Codex": "नया Codex", "发送": "भेजें", "输入消息": "संदेश लिखें", "发一条消息": "संदेश लिखें", "开始对话": "चैट शुरू करें", "对话": "बातचीत", "任务详情": "कार्य विवरण", "当前进度": "वर्तमान प्रगति", "模型": "मॉडल", "工作目录": "कार्य निर्देशिका", "继续对话": "बातचीत जारी रखें", "正在连接 ChatGPT…": "ChatGPT से कनेक्ट हो रहा है…", "还没有对话": "अभी कोई चैट नहीं",
        "在 iPhone 上确认 Codex：%@": "iPhone पर Codex की पुष्टि करें: %@", "需要 Face ID 才能批准此请求": "इस अनुरोध को मंज़ूर करने के लिए Face ID आवश्यक है", "iPhone 批准会先要求 Face ID": "iPhone पर अनुमोदन पहले Face ID मांगेगा", "佩戴手表并双击侧边按钮完成批准": "Apple Watch पहनें और मंज़ूरी के लिए साइड बटन पर दो बार क्लिक करें"
    ]
}
