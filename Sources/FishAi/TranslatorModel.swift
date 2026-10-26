import Foundation
import NaturalLanguage
import Translation

struct TargetLanguage: Identifiable, Hashable {
    let id: String
    let name: String
    var language: Locale.Language { Locale.Language(identifier: id) }

    /// "auto" 表示：原文是中文则译为英文，否则译为简体中文
    static let auto = TargetLanguage(id: "auto", name: "自动")
    static let all: [TargetLanguage] = [
        .auto,
        TargetLanguage(id: "zh-Hans", name: "简体中文"),
        TargetLanguage(id: "zh-Hant", name: "繁體中文"),
        TargetLanguage(id: "en", name: "English"),
        TargetLanguage(id: "ja", name: "日本語"),
        TargetLanguage(id: "ko", name: "한국어"),
        TargetLanguage(id: "fr", name: "Français"),
        TargetLanguage(id: "de", name: "Deutsch"),
        TargetLanguage(id: "es", name: "Español"),
    ]
}

@MainActor
final class TranslatorModel: ObservableObject {
    enum Phase: Equatable {
        case idle, recognizing, translating, done, failed(String)
    }

    @Published var sourceText = ""
    @Published var resultText = ""
    @Published var phase: Phase = .idle
    @Published var detectedSource: Locale.Language?
    @Published var target: TargetLanguage = .auto {
        didSet { if oldValue != target { translate() } }
    }
    /// 交给 SwiftUI `.translationTask` 使用；赋新值或 invalidate() 会触发一次翻译
    @Published var configuration: TranslationSession.Configuration?

    func beginRecognizing() {
        sourceText = ""
        resultText = ""
        detectedSource = nil
        phase = .recognizing
    }

    func setSource(_ text: String) {
        sourceText = text
        translate()
    }

    func fail(_ message: String) {
        phase = .failed(message)
    }

    func translate() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            phase = .failed("未识别到文字")
            return
        }
        let source = Self.detectLanguage(text)
        detectedSource = source
        let targetLanguage = resolvedTarget(for: source)

        let newConfig = TranslationSession.Configuration(source: source, target: targetLanguage)
        if configuration?.source == newConfig.source, configuration?.target == newConfig.target {
            configuration?.invalidate()
        } else {
            configuration = newConfig
        }
        phase = .translating
        NSLog("[FishAi] translate %@ -> %@", source?.minimalIdentifier ?? "auto", targetLanguage.minimalIdentifier)
    }

    func run(_ session: TranslationSession) async {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        NSLog("[FishAi] session ready")
        do {
            let response = try await session.translate(text)
            resultText = response.targetText
            detectedSource = response.sourceLanguage
            phase = .done
            NSLog("[FishAi] %@ -> %@", text, response.targetText)
        } catch {
            NSLog("[FishAi] translate failed: %@", String(describing: error))
            phase = .failed("翻译失败：\(error.localizedDescription)")
        }
    }

    private func resolvedTarget(for source: Locale.Language?) -> Locale.Language {
        if target != .auto { return target.language }
        if source?.languageCode == .chinese { return Locale.Language(identifier: "en") }
        return Locale.Language(identifier: "zh-Hans")
    }

    private static func detectLanguage(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }
}
