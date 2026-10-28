import Foundation

enum InteractionTranslations {
    static let keys = ["Codex 等待回答", "请回答问题以继续任务", "请完整回答当前问题", "填写回答", "提交回答", "等待电脑确认", "电脑已接收决定", "电脑尚未确认决定，请检查原任务", "打开软件查看并回答", "dot 已发送", "dot 已收到", "回答"]
    private static let rows: [AppLanguage: [String]] = [
        .simplifiedChinese: ["Codex 等待回答", "请回答问题以继续任务", "请完整回答当前问题", "填写回答", "提交回答", "等待电脑确认", "电脑已接收决定", "电脑尚未确认决定，请检查原任务", "打开软件查看并回答", "已发送", "dot 已收到", "回答"],
        .english: ["Codex needs your answer", "Answer to continue the task", "Please answer every current question", "Your answer", "Submit answer", "Waiting for Mac confirmation", "Mac received your decision", "Mac has not confirmed the decision. Check the original task.", "Open the app to review and respond", "Sent", "Received by dot", "Answer"],
        .spanish: ["Codex necesita tu respuesta", "Responde para continuar la tarea", "Responde todas las preguntas actuales", "Tu respuesta", "Enviar respuesta", "Esperando confirmación del Mac", "El Mac recibió tu decisión", "El Mac no ha confirmado la decisión. Revisa la tarea original.", "Abre la app para revisar y responder", "Enviado", "Recibido por dot", "Respuesta"],
        .french: ["Codex attend votre réponse", "Répondez pour poursuivre la tâche", "Répondez à chaque question actuelle", "Votre réponse", "Envoyer la réponse", "En attente de confirmation du Mac", "Le Mac a reçu votre décision", "Le Mac n’a pas confirmé la décision. Vérifiez la tâche d’origine.", "Ouvrez l’app pour consulter et répondre", "Envoyé", "Reçu par dot", "Réponse"],
        .german: ["Codex benötigt deine Antwort", "Zum Fortsetzen der Aufgabe antworten", "Bitte alle aktuellen Fragen beantworten", "Deine Antwort", "Antwort senden", "Warten auf Bestätigung vom Mac", "Mac hat deine Entscheidung erhalten", "Mac hat die Entscheidung nicht bestätigt. Ursprüngliche Aufgabe prüfen.", "App öffnen, prüfen und antworten", "Gesendet", "Von dot empfangen", "Antwort"],
        .japanese: ["Codex が回答を待っています", "回答してタスクを続行", "現在のすべての質問に回答してください", "回答", "回答を送信", "Mac の確認を待っています", "Mac が判断を受信しました", "Mac が判断を確認していません。元のタスクを確認してください。", "アプリを開いて確認・回答", "送信済み", "dot が受信済み", "回答"],
        .korean: ["Codex가 답변을 기다립니다", "답변하여 작업 계속하기", "현재 모든 질문에 답변하세요", "답변", "답변 제출", "Mac 확인 기다리는 중", "Mac이 결정을 받았습니다", "Mac이 결정을 확인하지 않았습니다. 원래 작업을 확인하세요.", "앱을 열어 확인하고 답변하세요", "전송됨", "dot이 수신함", "답변"],
        .portuguese: ["Codex precisa da sua resposta", "Responda para continuar a tarefa", "Responda a todas as perguntas atuais", "Sua resposta", "Enviar resposta", "Aguardando confirmação do Mac", "O Mac recebeu sua decisão", "O Mac não confirmou a decisão. Confira a tarefa original.", "Abra o app para revisar e responder", "Enviado", "Recebido pelo dot", "Resposta"],
        .italian: ["Codex attende la tua risposta", "Rispondi per continuare l’attività", "Rispondi a tutte le domande attuali", "La tua risposta", "Invia risposta", "In attesa di conferma dal Mac", "Il Mac ha ricevuto la decisione", "Il Mac non ha confermato la decisione. Controlla l’attività originale.", "Apri l’app per controllare e rispondere", "Inviato", "Ricevuto da dot", "Risposta"],
        .russian: ["Codex ждёт вашего ответа", "Ответьте, чтобы продолжить задачу", "Ответьте на все текущие вопросы", "Ваш ответ", "Отправить ответ", "Ожидание подтверждения Mac", "Mac получил ваше решение", "Mac не подтвердил решение. Проверьте исходную задачу.", "Откройте приложение и ответьте", "Отправлено", "Получено dot", "Ответ"],
        .arabic: ["ينتظر Codex إجابتك", "أجب لمتابعة المهمة", "يرجى الإجابة عن كل الأسئلة الحالية", "إجابتك", "إرسال الإجابة", "بانتظار تأكيد Mac", "تلقى Mac قرارك", "لم يؤكد Mac القرار. تحقق من المهمة الأصلية.", "افتح التطبيق للمراجعة والرد", "تم الإرسال", "استلمها dot", "الإجابة"],
        .hindi: ["Codex आपके जवाब की प्रतीक्षा में है", "काम जारी रखने के लिए जवाब दें", "कृपया सभी मौजूदा सवालों के जवाब दें", "आपका जवाब", "जवाब भेजें", "Mac की पुष्टि की प्रतीक्षा", "Mac को आपका निर्णय मिल गया", "Mac ने निर्णय की पुष्टि नहीं की। मूल काम जाँचें।", "देखने और जवाब देने के लिए ऐप खोलें", "भेजा गया", "dot को मिल गया", "जवाब"],
    ]
    static func text(_ key: String, language: AppLanguage) -> String? {
        guard let index = keys.firstIndex(of: key), let values = rows[language.resolved], values.count == keys.count else { return nil }
        return values[index]
    }
}
