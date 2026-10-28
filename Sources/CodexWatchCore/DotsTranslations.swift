import Foundation

enum DotsTranslations {
    private static let deliveryKeys = ["dot 云端已接收", "dot 等待读取", "dot 已回复"]
    private static let deliveryRows: [AppLanguage: [String]] = [
        .simplifiedChinese: ["云端已接收", "等待 dot 读取", "已回复"],
        .english: ["Received by cloud", "Waiting for dot to read", "Replied"],
        .spanish: ["Recibido en la nube", "Esperando que dot lo lea", "Respondido"],
        .french: ["Reçu dans le cloud", "En attente de lecture par dot", "Répondu"],
        .german: ["In der Cloud empfangen", "Warten, bis dot liest", "Beantwortet"],
        .japanese: ["クラウドで受信済み", "dot の読み取り待ち", "返信済み"],
        .korean: ["클라우드에서 수신됨", "dot이 읽기를 기다리는 중", "답변 완료"],
        .portuguese: ["Recebido na nuvem", "Aguardando leitura pelo dot", "Respondido"],
        .italian: ["Ricevuto nel cloud", "In attesa di lettura da dot", "Risposto"],
        .russian: ["Получено в облаке", "Ожидание прочтения dot", "Ответ получен"],
        .arabic: ["تم الاستلام في السحابة", "بانتظار قراءة dot", "تم الرد"],
        .hindi: ["क्लाउड में प्राप्त", "dot के पढ़ने की प्रतीक्षा", "जवाब मिल गया"],
    ]
    private static let eventKeys = ["dot 云端渠道说明", "dot 连接就绪", "dot 尚未订阅", "dot 回复较慢", "dot 投递失败"]
    private static let eventRows: [AppLanguage: [String]] = [
        .simplifiedChinese: ["云端 dot 对话。审批请在 ChatGPT 处理。", "收发已连接", "dot 尚未订阅，请在 ChatGPT 检查连接。", "回复较慢，仍在等待。无需重复发送。", "消息未能投递，请检查 dot 连接。"],
        .english: ["Cloud dot conversations. Handle approvals in ChatGPT.", "Messaging connected", "dot is not subscribed. Check the connection in ChatGPT.", "The reply is taking longer. No need to resend.", "Message delivery failed. Check the dot connection."],
        .spanish: ["Conversaciones con dot en la nube. Gestiona las autorizaciones en ChatGPT.", "Mensajería conectada", "dot no está suscrito. Comprueba la conexión en ChatGPT.", "La respuesta tarda más. No hace falta reenviar.", "Falló la entrega. Comprueba la conexión con dot."],
        .french: ["Conversations avec dot dans le cloud. Gérez les autorisations dans ChatGPT.", "Messagerie connectée", "dot n’est pas abonné. Vérifiez la connexion dans ChatGPT.", "La réponse prend plus de temps. Inutile de renvoyer.", "Échec de l’envoi. Vérifiez la connexion à dot."],
        .german: ["Cloud-Unterhaltungen mit dot. Genehmigungen in ChatGPT bearbeiten.", "Nachrichten verbunden", "dot ist nicht abonniert. Verbindung in ChatGPT prüfen.", "Die Antwort dauert länger. Nicht erneut senden.", "Zustellung fehlgeschlagen. Verbindung zu dot prüfen."],
        .japanese: ["クラウドの dot との会話です。承認は ChatGPT で行ってください。", "メッセージ接続済み", "dot が未購読です。ChatGPT で接続を確認してください。", "返信に時間がかかっています。再送は不要です。", "メッセージを配信できませんでした。dot の接続を確認してください。"],
        .korean: ["클라우드 dot 대화입니다. 승인은 ChatGPT에서 처리하세요.", "메시지 연결됨", "dot이 구독하지 않았습니다. ChatGPT에서 연결을 확인하세요.", "응답이 지연되고 있습니다. 다시 보내지 않아도 됩니다.", "메시지 전달에 실패했습니다. dot 연결을 확인하세요."],
        .portuguese: ["Conversas com dot na nuvem. Trate aprovações no ChatGPT.", "Mensagens conectadas", "dot não está inscrito. Verifique a conexão no ChatGPT.", "A resposta está demorando. Não é preciso reenviar.", "Falha na entrega. Verifique a conexão com dot."],
        .italian: ["Conversazioni con dot nel cloud. Gestisci le approvazioni in ChatGPT.", "Messaggistica connessa", "dot non è iscritto. Verifica la connessione in ChatGPT.", "La risposta richiede più tempo. Non serve reinviare.", "Consegna non riuscita. Verifica la connessione a dot."],
        .russian: ["Облачные диалоги с dot. Разрешения подтверждайте в ChatGPT.", "Обмен сообщениями подключён", "dot не подписан. Проверьте подключение в ChatGPT.", "Ответ задерживается. Не нужно отправлять повторно.", "Не удалось доставить сообщение. Проверьте подключение к dot."],
        .arabic: ["محادثات dot السحابية. تعامل مع الموافقات في ChatGPT.", "المراسلة متصلة", "dot غير مشترك. تحقق من الاتصال في ChatGPT.", "الرد يستغرق وقتًا أطول. لا حاجة لإعادة الإرسال.", "فشل تسليم الرسالة. تحقق من اتصال dot."],
        .hindi: ["क्लाउड में dot बातचीत। अनुमतियाँ ChatGPT में दें।", "मैसेजिंग जुड़ी हुई है", "dot ने सदस्यता नहीं ली है। ChatGPT में कनेक्शन जाँचें।", "जवाब में अधिक समय लग रहा है। फिर से भेजने की आवश्यकता नहीं है।", "संदेश नहीं पहुँच सका। dot कनेक्शन जाँचें।"],
    ]
    private static let keys = ["dot 新消息", "dot 尚未配置", "dot 对话", "dot 暂无对话", "dot 更多对话", "dot 渠道说明", "dot 你", "dot 在 Slack 处理审批", "dot 更多消息", "dot 等待回复", "dot 送达状态未确认", "dot 检查送达", "dot 输入消息", "dot 正在发送", "dot 发送", "dot 需要重新授权", "dot 请稍后重试", "dot 暂时无法连接"]
    private static let rows: [AppLanguage: [String]] = [
        .simplifiedChinese: ["新消息", "dot 尚未配置", "对话", "暂无对话", "更多对话", "这里显示 dot 的 Slack 对话。正式审批请在 Slack 或 ChatGPT 处理。", "你", "请在 Slack 处理此审批", "更多消息", "等待 dot 回复…", "送达状态未确认，不会自动重复发送。", "检查并重试", "输入消息", "正在发送…", "发送", "dot 需要重新授权", "请求较频繁，请稍后重试。", "暂时无法连接 dot，请下拉重试。"],
        .english: ["New message", "dot is not configured", "Conversations", "No conversations yet", "More conversations", "These are your dot conversations in Slack. Handle formal approvals in Slack or ChatGPT.", "You", "Handle this approval in Slack", "More messages", "Waiting for dot…", "Delivery is unconfirmed. Nothing will be resent automatically.", "Check and retry", "Message", "Sending…", "Send", "dot needs authorization again", "Too many requests. Try again shortly.", "Cannot connect to dot. Pull to retry."],
        .spanish: ["Nuevo mensaje", "dot no está configurado", "Conversaciones", "Aún no hay conversaciones", "Más conversaciones", "Estas son tus conversaciones con dot en Slack. Gestiona las autorizaciones formales en Slack o ChatGPT.", "Tú", "Gestiona esta autorización en Slack", "Más mensajes", "Esperando a dot…", "Entrega sin confirmar. No se reenviará automáticamente.", "Comprobar y reintentar", "Mensaje", "Enviando…", "Enviar", "dot necesita autorización de nuevo", "Demasiadas solicitudes. Reintenta en breve.", "No se puede conectar a dot. Desliza para reintentar."],
        .french: ["Nouveau message", "dot n’est pas configuré", "Conversations", "Aucune conversation", "Plus de conversations", "Voici vos conversations avec dot dans Slack. Gérez les autorisations formelles dans Slack ou ChatGPT.", "Vous", "Gérez cette autorisation dans Slack", "Plus de messages", "En attente de dot…", "Envoi non confirmé. Aucun renvoi automatique.", "Vérifier et réessayer", "Message", "Envoi…", "Envoyer", "dot doit être autorisé à nouveau", "Trop de requêtes. Réessayez bientôt.", "Connexion à dot impossible. Tirez pour réessayer."],
        .german: ["Neue Nachricht", "dot ist nicht konfiguriert", "Unterhaltungen", "Noch keine Unterhaltungen", "Mehr Unterhaltungen", "Dies sind deine dot-Unterhaltungen in Slack. Formelle Genehmigungen erfolgen in Slack oder ChatGPT.", "Du", "Diese Genehmigung in Slack bearbeiten", "Mehr Nachrichten", "Warten auf dot…", "Zustellung unbestätigt. Kein automatischer Neuversand.", "Prüfen und erneut versuchen", "Nachricht", "Wird gesendet…", "Senden", "dot muss erneut autorisiert werden", "Zu viele Anfragen. Bald erneut versuchen.", "Keine Verbindung zu dot. Zum Wiederholen ziehen."],
        .japanese: ["新しいメッセージ", "dot が未設定です", "会話", "会話はまだありません", "さらに会話を表示", "Slack 上の dot との会話です。正式な承認は Slack または ChatGPT で行ってください。", "あなた", "この承認は Slack で行ってください", "さらにメッセージを表示", "dot の返信を待っています…", "送信結果は未確認です。自動で再送しません。", "確認して再試行", "メッセージ", "送信中…", "送信", "dot の再認証が必要です", "リクエストが多すぎます。しばらくして再試行してください。", "dot に接続できません。下に引いて再試行してください。"],
        .korean: ["새 메시지", "dot이 설정되지 않았습니다", "대화", "아직 대화가 없습니다", "대화 더 보기", "Slack의 dot 대화입니다. 공식 승인은 Slack 또는 ChatGPT에서 처리하세요.", "나", "Slack에서 이 승인을 처리하세요", "메시지 더 보기", "dot 응답 기다리는 중…", "전달 여부가 확인되지 않았습니다. 자동으로 재전송하지 않습니다.", "확인 후 재시도", "메시지", "전송 중…", "보내기", "dot 재인증이 필요합니다", "요청이 너무 많습니다. 잠시 후 다시 시도하세요.", "dot에 연결할 수 없습니다. 아래로 당겨 재시도하세요."],
        .portuguese: ["Nova mensagem", "dot não está configurado", "Conversas", "Ainda não há conversas", "Mais conversas", "Estas são suas conversas com dot no Slack. Trate aprovações formais no Slack ou ChatGPT.", "Você", "Trate esta aprovação no Slack", "Mais mensagens", "Aguardando dot…", "Entrega não confirmada. Não haverá reenvio automático.", "Verificar e tentar novamente", "Mensagem", "Enviando…", "Enviar", "dot precisa de nova autorização", "Muitas solicitações. Tente novamente em breve.", "Não foi possível conectar ao dot. Puxe para tentar novamente."],
        .italian: ["Nuovo messaggio", "dot non è configurato", "Conversazioni", "Nessuna conversazione", "Altre conversazioni", "Queste sono le tue conversazioni con dot su Slack. Gestisci le approvazioni formali su Slack o ChatGPT.", "Tu", "Gestisci questa approvazione su Slack", "Altri messaggi", "In attesa di dot…", "Consegna non confermata. Nessun reinvio automatico.", "Verifica e riprova", "Messaggio", "Invio…", "Invia", "dot richiede una nuova autorizzazione", "Troppe richieste. Riprova tra poco.", "Impossibile connettersi a dot. Trascina per riprovare."],
        .russian: ["Новое сообщение", "dot не настроен", "Диалоги", "Диалогов пока нет", "Ещё диалоги", "Это ваши диалоги с dot в Slack. Официальные разрешения подтверждайте в Slack или ChatGPT.", "Вы", "Подтвердите это разрешение в Slack", "Ещё сообщения", "Ожидание ответа dot…", "Доставка не подтверждена. Автоматической повторной отправки не будет.", "Проверить и повторить", "Сообщение", "Отправка…", "Отправить", "dot требует повторной авторизации", "Слишком много запросов. Повторите позже.", "Нет связи с dot. Потяните вниз для повтора."],
        .arabic: ["رسالة جديدة", "لم يتم إعداد dot", "المحادثات", "لا توجد محادثات بعد", "مزيد من المحادثات", "هذه محادثاتك مع dot في Slack. تعامل مع الموافقات الرسمية في Slack أو ChatGPT.", "أنت", "تعامل مع هذه الموافقة في Slack", "مزيد من الرسائل", "بانتظار رد dot…", "لم يتم تأكيد التسليم. لن تتم إعادة الإرسال تلقائيًا.", "تحقق وأعد المحاولة", "رسالة", "جارٍ الإرسال…", "إرسال", "يحتاج dot إلى تفويض جديد", "طلبات كثيرة. حاول مجددًا بعد قليل.", "تعذّر الاتصال بـ dot. اسحب لإعادة المحاولة."],
        .hindi: ["नया संदेश", "dot कॉन्फ़िगर नहीं है", "बातचीत", "अभी कोई बातचीत नहीं", "और बातचीत", "ये Slack में आपकी dot बातचीत हैं। औपचारिक अनुमतियाँ Slack या ChatGPT में दें।", "आप", "यह अनुमति Slack में दें", "और संदेश", "dot के जवाब की प्रतीक्षा…", "डिलीवरी की पुष्टि नहीं हुई। अपने आप दोबारा नहीं भेजा जाएगा।", "जाँचें और फिर कोशिश करें", "संदेश", "भेजा जा रहा है…", "भेजें", "dot को फिर से अनुमति चाहिए", "बहुत अधिक अनुरोध। थोड़ी देर बाद कोशिश करें।", "dot से कनेक्ट नहीं हो सका। फिर कोशिश करने के लिए नीचे खींचें।"],
    ]
    static func text(_ key: String, language: AppLanguage) -> String? {
        if key == "dot 云端日额度耗尽" {
            let values: [AppLanguage: String] = [
                .simplifiedChinese: "云端今日读取额度已用尽，将在每日 00:00 UTC 重置。无需重复发送。",
                .english: "Today's cloud read allowance is exhausted. It resets daily at 00:00 UTC. No need to resend.",
                .spanish: "Se agotó la cuota diaria de lectura. Se restablece a las 00:00 UTC. No hace falta reenviar.",
                .french: "Le quota quotidien de lecture est épuisé. Réinitialisation à 00:00 UTC. Inutile de renvoyer.",
                .german: "Das tägliche Cloud-Leselimit ist erreicht. Es wird um 00:00 UTC zurückgesetzt. Nicht erneut senden.",
                .japanese: "本日のクラウド読み取り上限に達しました。毎日 00:00 UTC にリセットされます。再送は不要です。",
                .korean: "오늘의 클라우드 읽기 한도에 도달했습니다. 매일 00:00 UTC에 초기화됩니다. 다시 보내지 않아도 됩니다.",
                .portuguese: "A cota diária de leitura foi esgotada. Ela é renovada às 00:00 UTC. Não é preciso reenviar.",
                .italian: "La quota giornaliera di lettura è esaurita. Si rinnova alle 00:00 UTC. Non serve reinviare.",
                .russian: "Дневной лимит чтения исчерпан. Он обновляется в 00:00 UTC. Повторная отправка не нужна.",
                .arabic: "نفدت حصة القراءة السحابية اليومية. تُجدَّد عند 00:00 UTC. لا حاجة لإعادة الإرسال.",
                .hindi: "आज की क्लाउड पढ़ने की सीमा समाप्त हो गई है। यह रोज़ 00:00 UTC पर रीसेट होती है। दोबारा न भेजें।"
            ]
            return values[language.resolved]
        }
        if key == "dot 同步延迟" {
            let values: [AppLanguage: String] = [
                .simplifiedChinese: "记录同步较慢，仍可稍后补齐。无需重复请求。",
                .english: "History sync is delayed. It can still complete; no need to request again.",
                .spanish: "La sincronización se retrasa. Aún puede completarse; no repitas la solicitud.",
                .french: "La synchronisation est retardée. Elle peut encore aboutir ; inutile de la relancer.",
                .german: "Die Synchronisierung verzögert sich. Sie kann noch abgeschlossen werden; nicht erneut anfordern.",
                .japanese: "履歴の同期が遅れています。後で完了できます。再要求は不要です。",
                .korean: "기록 동기화가 지연되고 있습니다. 나중에 완료될 수 있으니 다시 요청하지 않아도 됩니다.",
                .portuguese: "A sincronização está atrasada. Ainda pode terminar; não repita a solicitação.",
                .italian: "La sincronizzazione è in ritardo. Può ancora completarsi; non ripetere la richiesta.",
                .russian: "Синхронизация задерживается. Она ещё может завершиться; повторный запрос не нужен.",
                .arabic: "تأخرت مزامنة السجل. لا يزال بإمكانها الاكتمال؛ لا حاجة لتكرار الطلب.",
                .hindi: "इतिहास सिंक में देरी है। यह अभी भी पूरा हो सकता है; फिर से अनुरोध न करें।"
            ]
            return values[language.resolved]
        }
        if key == "dot 正在同步" || key == "dot 近期记录" {
            let values: [AppLanguage: [String]] = [
                .simplifiedChinese: ["正在同步 Your dot…", "已同步近期记录；更早的官方记录暂未回填。"],
                .english: ["Syncing Your dot…", "Recent history synced. Older official history is not yet imported."],
                .spanish: ["Sincronizando Your dot…", "Historial reciente sincronizado. El historial oficial anterior aún no se ha importado."],
                .french: ["Synchronisation de Your dot…", "Historique récent synchronisé. L’ancien historique officiel n’est pas encore importé."],
                .german: ["Your dot wird synchronisiert…", "Aktueller Verlauf synchronisiert. Älterer offizieller Verlauf ist noch nicht importiert."],
                .japanese: ["Your dot を同期中…", "最近の履歴を同期しました。以前の公式履歴は未取り込みです。"],
                .korean: ["Your dot 동기화 중…", "최근 기록이 동기화되었습니다. 이전 공식 기록은 아직 가져오지 않았습니다."],
                .portuguese: ["Sincronizando Your dot…", "Histórico recente sincronizado. O histórico oficial anterior ainda não foi importado."],
                .italian: ["Sincronizzazione di Your dot…", "Cronologia recente sincronizzata. La cronologia ufficiale precedente non è ancora importata."],
                .russian: ["Синхронизация Your dot…", "Недавняя история синхронизирована. Более ранняя официальная история ещё не импортирована."],
                .arabic: ["جارٍ مزامنة Your dot…", "تمت مزامنة السجل الحديث. لم يُستورد السجل الرسمي الأقدم بعد."],
                .hindi: ["Your dot सिंक हो रहा है…", "हाल का इतिहास सिंक हुआ। पुराना आधिकारिक इतिहास अभी आयात नहीं हुआ है।"]
            ]
            return values[language.resolved]?[key == "dot 正在同步" ? 0 : 1]
        }
        if let index = deliveryKeys.firstIndex(of: key), let row = deliveryRows[language.resolved], row.count == deliveryKeys.count { return row[index] }
        if let index = eventKeys.firstIndex(of: key), let row = eventRows[language.resolved], row.count == eventKeys.count { return row[index] }
        if key == "dot 消息太长" {
            let values: [AppLanguage: String] = [.simplifiedChinese: "消息最多 4000 个字符。", .english: "Messages can contain up to 4000 characters.", .spanish: "Los mensajes pueden tener hasta 4000 caracteres.", .french: "Les messages sont limités à 4000 caractères.", .german: "Nachrichten dürfen bis zu 4000 Zeichen enthalten.", .japanese: "メッセージは4000文字までです。", .korean: "메시지는 최대 4000자입니다.", .portuguese: "As mensagens podem ter até 4000 caracteres.", .italian: "I messaggi possono contenere fino a 4000 caratteri.", .russian: "Сообщения могут содержать до 4000 символов.", .arabic: "يمكن أن تحتوي الرسائل على 4000 حرف كحد أقصى.", .hindi: "संदेश में अधिकतम 4000 अक्षर हो सकते हैं।"]
            return values[language.resolved]
        }
        guard let index = keys.firstIndex(of: key), let row = rows[language.resolved], row.count == keys.count else { return nil }
        return row[index]
    }
}
