import Foundation

/// Small feature packs share the same language coverage as the main UI.
enum FeatureTranslations {
    private static let keys = ["加载较早的消息", "正在加载…", "无法加载聊天记录，请重试", "重试", "上次确认的状态", "中继不可用"]
    private static let rows: [AppLanguage: [String]] = [
        .english: ["Load earlier messages", "Loading…", "Could not load history. Try again.", "Retry", "Last verified status", "Relay unavailable"],
        .spanish: ["Cargar mensajes anteriores", "Cargando…", "No se pudo cargar el historial. Inténtalo de nuevo.", "Reintentar", "Último estado verificado", "Retransmisión no disponible"],
        .french: ["Charger les messages précédents", "Chargement…", "Impossible de charger l’historique. Réessayez.", "Réessayer", "Dernier état vérifié", "Relais indisponible"],
        .german: ["Frühere Nachrichten laden", "Wird geladen…", "Verlauf konnte nicht geladen werden. Erneut versuchen.", "Erneut versuchen", "Zuletzt bestätigter Status", "Relay nicht verfügbar"],
        .japanese: ["以前のメッセージを読み込む", "読み込み中…", "履歴を読み込めませんでした。再試行してください。", "再試行", "最後に確認された状態", "リレーを利用できません"],
        .korean: ["이전 메시지 불러오기", "불러오는 중…", "기록을 불러오지 못했습니다. 다시 시도하세요.", "다시 시도", "마지막으로 확인된 상태", "릴레이 사용 불가"],
        .portuguese: ["Carregar mensagens anteriores", "Carregando…", "Não foi possível carregar o histórico. Tente novamente.", "Tentar novamente", "Último estado verificado", "Relay indisponível"],
        .italian: ["Carica messaggi precedenti", "Caricamento…", "Impossibile caricare la cronologia. Riprova.", "Riprova", "Ultimo stato verificato", "Relay non disponibile"],
        .russian: ["Загрузить предыдущие сообщения", "Загрузка…", "Не удалось загрузить историю. Повторите попытку.", "Повторить", "Последний подтверждённый статус", "Ретранслятор недоступен"],
        .arabic: ["تحميل الرسائل السابقة", "جارٍ التحميل…", "تعذّر تحميل السجل. حاول مجددًا.", "إعادة المحاولة", "آخر حالة تم التحقق منها", "خدمة الترحيل غير متاحة"],
        .hindi: ["पुराने संदेश लोड करें", "लोड हो रहा है…", "इतिहास लोड नहीं हो सका। फिर कोशिश करें।", "फिर कोशिश करें", "आखिरी सत्यापित स्थिति", "रिले उपलब्ध नहीं है"],
    ]

    private static let activityKeys = ["系统允许实时活动", "活动显示与后台刷新由系统管理，信息可能暂时滞后。"]
    private static let activityRows: [AppLanguage: [String]] = [
        .english: ["Live Activities are allowed", "Display and background refresh are managed by the system. Updates may be delayed."],
        .spanish: ["Actividades en vivo permitidas", "El sistema gestiona la visualización y la actualización en segundo plano. Puede haber retrasos."],
        .french: ["Activités en direct autorisées", "L’affichage et l’actualisation en arrière-plan sont gérés par le système. Les mises à jour peuvent être retardées."],
        .german: ["Live-Aktivitäten sind erlaubt", "Anzeige und Hintergrundaktualisierung werden vom System gesteuert. Aktualisierungen können verzögert sein."],
        .japanese: ["ライブアクティビティが許可されています", "表示とバックグラウンド更新はシステムが管理します。更新が遅れる場合があります。"],
        .korean: ["실시간 현황 허용됨", "표시와 백그라운드 새로 고침은 시스템이 관리합니다. 업데이트가 지연될 수 있습니다."],
        .portuguese: ["Atividades ao vivo permitidas", "A exibição e a atualização em segundo plano são gerenciadas pelo sistema. Pode haver atrasos."],
        .italian: ["Attività live consentite", "La visualizzazione e l’aggiornamento in background sono gestiti dal sistema. Gli aggiornamenti possono essere ritardati."],
        .russian: ["Текущие действия разрешены", "Отображение и фоновое обновление управляются системой. Возможны задержки обновлений."],
        .arabic: ["الأنشطة المباشرة مسموحة", "يدير النظام العرض والتحديث في الخلفية. قد تتأخر التحديثات."],
        .hindi: ["लाइव गतिविधियों की अनुमति है", "प्रदर्शन और बैकग्राउंड अपडेट सिस्टम द्वारा नियंत्रित हैं। अपडेट में देरी हो सकती है।"],
    ]

    private static let wristKeys = ["佩戴并解锁手表，启用腕部检测后批准", "请佩戴并解锁手表，开启腕部检测后重试"]
    private static let wristRows: [AppLanguage: [String]] = [
        .english: ["Approve while wearing your unlocked Watch with wrist detection on", "Wear and unlock your Watch, turn on wrist detection, then try again"],
        .spanish: ["Aprueba con el reloj puesto y desbloqueado, con detección de muñeca activada", "Ponte y desbloquea el reloj, activa la detección de muñeca e inténtalo de nuevo"],
        .french: ["Approuvez en portant votre montre déverrouillée avec la détection du poignet activée", "Portez et déverrouillez votre montre, activez la détection du poignet, puis réessayez"],
        .german: ["Mit getragener, entsperrter Watch und aktivierter Handgelenkerkennung genehmigen", "Watch tragen und entsperren, Handgelenkerkennung aktivieren und erneut versuchen"],
        .japanese: ["手首検出をオンにして、装着中のロック解除済み Watch で承認", "Watch を装着してロックを解除し、手首検出をオンにして再試行してください"],
        .korean: ["손목 감지를 켜고 착용 중인 잠금 해제된 Watch에서 승인", "Watch를 착용하고 잠금을 해제한 뒤 손목 감지를 켜고 다시 시도하세요"],
        .portuguese: ["Aprove usando o Watch desbloqueado com detecção de pulso ativada", "Coloque e desbloqueie o Watch, ative a detecção de pulso e tente novamente"],
        .italian: ["Approva indossando il Watch sbloccato con rilevamento del polso attivo", "Indossa e sblocca il Watch, attiva il rilevamento del polso e riprova"],
        .russian: ["Подтвердите на надетых разблокированных часах с распознаванием запястья", "Наденьте и разблокируйте часы, включите распознавание запястья и повторите попытку"],
        .arabic: ["وافق أثناء ارتداء Watch غير المقفلة مع تشغيل اكتشاف المعصم", "ارتدِ Watch وافتح قفلها وشغّل اكتشاف المعصم ثم حاول مجددًا"],
        .hindi: ["कलाई की पहचान चालू रखें और पहनी हुई अनलॉक Watch से अनुमति दें", "Watch पहनें और अनलॉक करें, कलाई की पहचान चालू करें और फिर कोशिश करें"],
    ]

    static func text(_ key: String, language: AppLanguage) -> String? {
        if let value = ModelTranslations.text(key, language: language) { return value }
        if let value = InteractionTranslations.text(key, language: language) { return value }
        if let value = DotsTranslations.text(key, language: language) { return value }
        if let index = wristKeys.firstIndex(of: key), let values = wristRows[language.resolved] {
            return values[index]
        }
        if let index = activityKeys.firstIndex(of: key), let values = activityRows[language.resolved] {
            return values[index]
        }
        guard let index = keys.firstIndex(of: key), let values = rows[language.resolved] else { return nil }
        return values[index]
    }
}
