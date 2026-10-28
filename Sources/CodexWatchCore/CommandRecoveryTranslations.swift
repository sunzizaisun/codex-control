import Foundation

enum CommandRecoveryTranslations {
    private static let interfaceKeys = ["查询发送结果", "正在查询…", "丢弃本机草稿", "这只移除本机草稿，不会取消已提交的操作，也不会重新发送。", "暂未找到回执，执行结果仍未确认。", "无法确认，请检查连接并查看原任务。"]
    private static let statusKeys = ["上次操作结果未确认，请先检查原任务。", "远程数据校验失败", "本机存储不可用，发送已暂停。请保留草稿并重试。", "指令内容过长，请缩短后重试。"]
    static let keys = interfaceKeys + statusKeys + RecoveryReviewTranslations.keys
    /// Only relocalize our small, exact recovery vocabulary for presentation.
    /// This does not classify receipts, translate arbitrary owner errors, or
    /// alter user input. Stored notices can follow a mounted language change.
    static func relocalizedNotice(_ value: String, language: AppLanguage?) -> String {
        for key in statusKeys + Array(interfaceKeys.suffix(2)) {
            if AppLanguage.allCases.filter({ $0 != .system }).contains(where: { text(key, language: $0) == value }) {
                return language.map { AppLocalizer.text(key, language: $0) } ?? AppLocalizer.text(key)
            }
        }
        return value
    }
    private static let rows: [AppLanguage: [String]] = [
        .simplifiedChinese: interfaceKeys,
        .english: ["Check delivery result", "Checking…", "Discard local draft", "This only removes the local draft. It does not cancel a submitted action or send it again.", "No receipt found yet. Execution is still unconfirmed.", "Could not confirm. Check the connection and the original task."],
        .spanish: ["Consultar el envío", "Consultando…", "Descartar borrador local", "Solo se elimina el borrador local. No cancela una acción enviada ni la vuelve a enviar.", "Aún no se encontró confirmación. La ejecución sigue sin confirmar.", "No se pudo confirmar. Revisa la conexión y la tarea original."],
        .french: ["Vérifier l’envoi", "Vérification…", "Supprimer le brouillon local", "Cela supprime uniquement le brouillon local, sans annuler ni renvoyer une action déjà soumise.", "Aucun accusé trouvé. L’exécution reste non confirmée.", "Confirmation impossible. Vérifiez la connexion et la tâche d’origine."],
        .german: ["Sendeergebnis prüfen", "Wird geprüft…", "Lokalen Entwurf verwerfen", "Dies entfernt nur den lokalen Entwurf. Eine gesendete Aktion wird weder abgebrochen noch erneut gesendet.", "Noch kein Beleg gefunden. Die Ausführung bleibt unbestätigt.", "Keine Bestätigung möglich. Verbindung und ursprüngliche Aufgabe prüfen."],
        .japanese: ["送信結果を確認", "確認中…", "端末内の下書きを破棄", "端末内の下書きだけを削除します。送信済みの操作の取消や再送は行いません。", "受領記録が見つかりません。実行結果は未確認です。", "確認できません。接続と元のタスクを確認してください。"],
        .korean: ["전송 결과 확인", "확인 중…", "기기 내 초안 삭제", "기기 내 초안만 삭제합니다. 이미 제출한 작업을 취소하거나 다시 전송하지 않습니다.", "아직 수신 확인을 찾지 못했습니다. 실행 결과는 미확인입니다.", "확인할 수 없습니다. 연결과 원래 작업을 확인하세요."],
        .portuguese: ["Verificar envio", "Verificando…", "Descartar rascunho local", "Isso remove apenas o rascunho local. Não cancela nem reenvia uma ação já enviada.", "Nenhum comprovante encontrado. A execução segue sem confirmação.", "Não foi possível confirmar. Verifique a conexão e a tarefa original."],
        .italian: ["Verifica invio", "Verifica…", "Elimina bozza locale", "Rimuove solo la bozza locale. Non annulla né reinvia un’azione già inviata.", "Nessuna ricevuta trovata. L’esecuzione resta da confermare.", "Impossibile confermare. Controlla la connessione e l’attività originale."],
        .russian: ["Проверить отправку", "Проверка…", "Удалить локальный черновик", "Удаляется только локальный черновик. Отправленное действие не отменяется и не отправляется повторно.", "Квитанция пока не найдена. Выполнение не подтверждено.", "Не удалось подтвердить. Проверьте подключение и исходную задачу."],
        .arabic: ["التحقق من الإرسال", "جارٍ التحقق…", "حذف المسودة المحلية", "يُحذف فقط النص المحلي. لا يُلغى الإجراء المرسل ولا يُرسل مرة أخرى.", "لم يُعثر على إيصال بعد. التنفيذ غير مؤكد.", "تعذّر التأكيد. تحقق من الاتصال والمهمة الأصلية."],
        .hindi: ["भेजने का परिणाम जाँचें", "जाँच जारी…", "स्थानीय ड्राफ़्ट हटाएँ", "इससे केवल स्थानीय ड्राफ़्ट हटता है। भेजी गई कार्रवाई रद्द या दोबारा नहीं भेजी जाती।", "अभी रसीद नहीं मिली। कार्य का निष्पादन अपुष्ट है।", "पुष्टि नहीं हो सकी। कनेक्शन और मूल कार्य जाँचें।"],
    ]
    private static let statusRows: [AppLanguage: [String]] = [
        .simplifiedChinese: statusKeys,
        .english: ["The previous action's result is unknown. Check the original task first.", "Remote data verification failed", "Local storage is unavailable. Sending is paused. Keep your draft and try again.", "The command is too long. Shorten it and try again."],
        .spanish: ["El resultado de la acción anterior es desconocido. Revisa primero la tarea original.", "Falló la verificación de datos remotos", "El almacenamiento local no está disponible. El envío está en pausa. Conserva el borrador y vuelve a intentarlo.", "La instrucción es demasiado larga. Acórtala y vuelve a intentarlo."],
        .french: ["Le résultat de l’action précédente est inconnu. Vérifiez d’abord la tâche d’origine.", "Échec de la vérification des données distantes", "Le stockage local est indisponible. L’envoi est suspendu. Gardez votre brouillon et réessayez.", "L’instruction est trop longue. Raccourcissez-la et réessayez."],
        .german: ["Das Ergebnis der vorherigen Aktion ist unbekannt. Prüfe zuerst die ursprüngliche Aufgabe.", "Prüfung der entfernten Daten fehlgeschlagen", "Lokaler Speicher ist nicht verfügbar. Senden pausiert. Entwurf behalten und erneut versuchen.", "Die Anweisung ist zu lang. Bitte kürzen und erneut versuchen."],
        .japanese: ["前の操作の結果は未確認です。先に元のタスクを確認してください。", "リモートデータの検証に失敗しました", "端末の保存領域を利用できないため送信を停止しています。下書きを残して再試行してください。", "指示が長すぎます。短くして再試行してください。"],
        .korean: ["이전 작업의 결과가 미확인입니다. 먼저 원래 작업을 확인하세요.", "원격 데이터 검증 실패", "기기 저장 공간을 사용할 수 없어 전송을 일시 중지했습니다. 초안을 보관하고 다시 시도하세요.", "명령이 너무 깁니다. 줄인 후 다시 시도하세요."],
        .portuguese: ["O resultado da ação anterior é desconhecido. Verifique primeiro a tarefa original.", "Falha na verificação dos dados remotos", "O armazenamento local está indisponível. O envio está pausado. Guarde o rascunho e tente novamente.", "A instrução é longa demais. Encurte e tente novamente."],
        .italian: ["Il risultato dell’azione precedente è sconosciuto. Controlla prima l’attività originale.", "Verifica dei dati remoti non riuscita", "Memoria locale non disponibile. Invio sospeso. Conserva la bozza e riprova.", "L’istruzione è troppo lunga. Accorciala e riprova."],
        .russian: ["Результат предыдущего действия неизвестен. Сначала проверьте исходную задачу.", "Ошибка проверки удалённых данных", "Локальное хранилище недоступно. Отправка приостановлена. Сохраните черновик и повторите попытку.", "Слишком длинная команда. Сократите её и повторите попытку."],
        .arabic: ["نتيجة الإجراء السابق غير مؤكدة. تحقق من المهمة الأصلية أولاً.", "فشل التحقق من البيانات البعيدة", "التخزين المحلي غير متاح. تم إيقاف الإرسال مؤقتاً. احتفظ بالمسودة وحاول مرة أخرى.", "التعليمات طويلة جداً. اختصرها وحاول مرة أخرى."],
        .hindi: ["पिछली कार्रवाई का परिणाम अपुष्ट है। पहले मूल कार्य जाँचें।", "दूरस्थ डेटा का सत्यापन विफल रहा", "स्थानीय स्टोरेज उपलब्ध नहीं है। भेजना रोका गया है। ड्राफ़्ट सुरक्षित रखें और फिर कोशिश करें।", "निर्देश बहुत लंबा है। इसे छोटा करके फिर कोशिश करें।"],
    ]
    static func text(_ key: String, language: AppLanguage) -> String? {
        if let translated = RecoveryReviewTranslations.text(key, language: language) { return translated }
        if let index = statusKeys.firstIndex(of: key), let row = statusRows[language.resolved], row.count == statusKeys.count {
            return row[index]
        }
        guard let index = interfaceKeys.firstIndex(of: key), let row = rows[language.resolved], row.count == interfaceKeys.count else { return nil }
        return row[index]
    }
}
