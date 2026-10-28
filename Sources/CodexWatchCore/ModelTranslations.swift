import Foundation

enum ModelTranslations {
    private static let keys = ["推理强度", "连接 Mac 后加载模型", "运行中不能切换模型，请等待当前回合结束", "模型选项已变化，请刷新后重新选择", "等待你的回复", "effort.none", "effort.minimal", "effort.low", "effort.medium", "effort.high", "effort.xhigh", "effort.max", "effort.ultra"]
    private static let rows: [AppLanguage: [String]] = [
        .simplifiedChinese: ["推理强度", "连接 Mac 后加载模型", "当前回合结束后可切换模型；跟进沿用当前设置。", "模型选项已变化，请刷新后重新选择", "等待你的回复", "无", "极低", "低", "中", "高", "很高", "最高", "超强"],
        .english: ["Reasoning", "Connect to Mac to load models", "Change models after this turn. Follow-ups keep the current settings.", "Model options changed. Refresh and select again.", "Waiting for your reply", "None", "Minimal", "Low", "Medium", "High", "Extra high", "Maximum", "Ultra"],
        .spanish: ["Razonamiento", "Conecta el Mac para cargar modelos", "Cambia de modelo tras este turno. Los seguimientos conservan la configuración.", "Las opciones cambiaron. Actualiza y vuelve a seleccionar.", "Esperando tu respuesta", "Ninguno", "Mínimo", "Bajo", "Medio", "Alto", "Muy alto", "Máximo", "Ultra"],
        .french: ["Raisonnement", "Connectez le Mac pour charger les modèles", "Changez de modèle après ce tour. Les suivis conservent les réglages.", "Options modifiées. Actualisez et sélectionnez à nouveau.", "En attente de votre réponse", "Aucun", "Minimal", "Faible", "Moyen", "Élevé", "Très élevé", "Maximum", "Ultra"],
        .german: ["Denkaufwand", "Mac verbinden, um Modelle zu laden", "Modellwechsel nach dieser Runde. Nachfragen behalten die Einstellungen.", "Modelloptionen geändert. Aktualisieren und neu wählen.", "Warten auf deine Antwort", "Keiner", "Minimal", "Niedrig", "Mittel", "Hoch", "Sehr hoch", "Maximum", "Ultra"],
        .japanese: ["推論の強度", "Mac に接続してモデルを読み込む", "このターンの終了後に変更できます。追加指示は現在の設定を使います。", "モデルの選択肢が変わりました。更新して選び直してください。", "返信を待っています", "なし", "最小", "低", "中", "高", "とても高い", "最大", "ウルトラ"],
        .korean: ["추론 강도", "Mac에 연결하여 모델 불러오기", "이 턴이 끝난 후 변경할 수 있습니다. 후속 지시는 현재 설정을 유지합니다.", "모델 옵션이 변경되었습니다. 새로 고침 후 다시 선택하세요.", "답변 기다리는 중", "없음", "최소", "낮음", "중간", "높음", "매우 높음", "최대", "울트라"],
        .portuguese: ["Raciocínio", "Conecte ao Mac para carregar modelos", "Troque o modelo após este turno. As continuações mantêm os ajustes.", "As opções mudaram. Atualize e selecione novamente.", "Aguardando sua resposta", "Nenhum", "Mínimo", "Baixo", "Médio", "Alto", "Muito alto", "Máximo", "Ultra"],
        .italian: ["Ragionamento", "Collega il Mac per caricare i modelli", "Cambia modello dopo questo turno. I messaggi successivi mantengono le impostazioni.", "Opzioni cambiate. Aggiorna e seleziona di nuovo.", "In attesa della tua risposta", "Nessuno", "Minimo", "Basso", "Medio", "Alto", "Molto alto", "Massimo", "Ultra"],
        .russian: ["Усилие рассуждения", "Подключите Mac для загрузки моделей", "Модель можно сменить после этого хода. Уточнения сохраняют настройки.", "Параметры изменились. Обновите и выберите заново.", "Ожидание вашего ответа", "Нет", "Минимальное", "Низкое", "Среднее", "Высокое", "Очень высокое", "Максимальное", "Ультра"],
        .arabic: ["مستوى الاستدلال", "اتصل بـ Mac لتحميل النماذج", "غيّر النموذج بعد هذه الجولة. تحتفظ المتابعات بالإعدادات الحالية.", "تغيّرت الخيارات. حدّث واختر مجددًا.", "بانتظار ردك", "بلا", "أدنى", "منخفض", "متوسط", "عالٍ", "عالٍ جدًا", "أقصى", "فائق"],
        .hindi: ["तर्क स्तर", "मॉडल लोड करने के लिए Mac से जुड़ें", "इस चरण के बाद मॉडल बदलें। आगे के संदेश वर्तमान सेटिंग रखते हैं।", "विकल्प बदल गए। रीफ़्रेश करके फिर चुनें।", "आपके जवाब की प्रतीक्षा", "नहीं", "न्यूनतम", "कम", "मध्यम", "उच्च", "बहुत उच्च", "अधिकतम", "अल्ट्रा"],
    ]
    static func text(_ key: String, language: AppLanguage) -> String? {
        if key == "保持当前设置" {
            return [.simplifiedChinese: "保持当前设置", .english: "Keep current settings", .spanish: "Mantener configuración", .french: "Conserver les réglages", .german: "Aktuelle Einstellungen", .japanese: "現在の設定を維持", .korean: "현재 설정 유지", .portuguese: "Manter ajustes atuais", .italian: "Mantieni impostazioni", .russian: "Сохранить настройки", .arabic: "الاحتفاظ بالإعدادات", .hindi: "वर्तमान सेटिंग रखें"][language.resolved]
        }
        guard let index = keys.firstIndex(of: key), let row = rows[language.resolved] else { return nil }
        return row[index]
    }
}
