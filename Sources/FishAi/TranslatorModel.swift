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
        case idle, loading, done, failed(String)
    }

    /// 单个翻译服务的结果
    struct ServiceResult: Equatable {
        var phase: Phase = .idle
        var text = ""
    }

    let settings = AppSettings.shared

    @Published var sourceText = ""
    /// 当前原文的来源，写入翻译记录
    var origin: TranslationRecord.Origin = .manual
    @Published var isRecognizing = false
    @Published var sourceError: String?
    @Published var detectedSource: Locale.Language?
    @Published var target: TargetLanguage = .auto {
        didSet { if oldValue != target { translate() } }
    }
    @Published var system = ServiceResult()
    @Published var openAI = ServiceResult()
    /// 交给 SwiftUI `.translationTask` 使用；赋新值或 invalidate() 会触发一次系统翻译
    @Published var configuration: TranslationSession.Configuration?

    private var openAITask: Task<Void, Never>?
    /// 本次翻译实际使用的目标语言
    private var currentTarget = Locale.Language(identifier: "zh-Hans")

    func beginRecognizing(origin: TranslationRecord.Origin) {
        self.origin = origin
        openAITask?.cancel()
        sourceText = ""
        sourceError = nil
        detectedSource = nil
        system = ServiceResult()
        openAI = ServiceResult()
        isRecognizing = true
    }

    func setSource(_ text: String, origin: TranslationRecord.Origin) {
        self.origin = origin
        isRecognizing = false
        sourceText = text
        translate()
    }

    func fail(_ message: String) {
        isRecognizing = false
        sourceError = message
    }

    func translate() {
        openAITask?.cancel()
        system = ServiceResult()
        openAI = ServiceResult()

        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            sourceError = "未识别到文字"
            return
        }
        sourceError = nil
        let source = Self.detectLanguage(text)
        detectedSource = source
        let targetLanguage = resolvedTarget(for: source)
        currentTarget = targetLanguage

        if settings.systemEnabled {
            system.phase = .loading
            let newConfig = TranslationSession.Configuration(source: source, target: targetLanguage)
            if configuration?.source == newConfig.source, configuration?.target == newConfig.target {
                configuration?.invalidate()
            } else {
                configuration = newConfig
            }
        }

        if settings.openAIEnabled { startOpenAI(text) }
    }

    /// 切换模型或提示词后，只重新请求大模型这一张卡片
    func rerunOpenAI() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.openAIEnabled, !text.isEmpty, !isRecognizing else { return }
        startOpenAI(text)
    }

    private func startOpenAI(_ text: String) {
        openAITask?.cancel()
        openAI = ServiceResult(phase: .loading)
        let from = detectedSource.map(Self.englishName) ?? "the detected language"
        let to = Self.englishName(currentTarget)
        let config = settings.openAIConfig
        let label = [settings.selectedModel?.name, settings.selectedPrompt?.name]
            .compactMap { $0 }.joined(separator: " · ")
        openAITask = Task { await runOpenAI(text, from: from, to: to, config: config, label: label) }
    }

    /// 由 `.translationTask` 回调
    func run(_ session: TranslationSession) async {
        guard system.phase == .loading else { return }
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let response = try await session.translate(text)
            system = ServiceResult(phase: .done, text: response.targetText)
            detectedSource = response.sourceLanguage
            record(text, service: "system", model: nil, result: response.targetText)
        } catch {
            system.phase = .failed("翻译失败：\(error.localizedDescription)")
        }
    }

    private func runOpenAI(_ text: String, from: String, to: String, config: OpenAIClient.Config,
                           label: String) async {
        do {
            try await OpenAIClient.translate(text, from: from, to: to, config: config) { [weak self] delta in
                guard let self, !Task.isCancelled else { return }
                self.openAI.text += delta
            }
            guard !Task.isCancelled else { return }
            openAI.phase = .done
            record(text, service: "openai", model: label, result: openAI.text)
        } catch {
            guard !Task.isCancelled else { return }
            openAI.phase = .failed("请求失败：\(error.localizedDescription)")
        }
    }

    private func record(_ text: String, service: String, model: String?, result: String) {
        HistoryStore.shared.add(TranslationRecord(
            origin: origin, sourceText: text, sourceLang: detectedSource?.minimalIdentifier,
            targetLang: currentTarget.minimalIdentifier, service: service, model: model,
            resultText: result.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private func resolvedTarget(for source: Locale.Language?) -> Locale.Language {
        if target != .auto { return target.language }
        if source?.languageCode == .chinese { return Locale.Language(identifier: "en") }
        return Locale.Language(identifier: "zh-Hans")
    }

    /// 提示词里使用的英文语言名，如 "Chinese, Simplified"
    static func englishName(_ language: Locale.Language) -> String {
        var id = language.languageCode?.identifier ?? language.minimalIdentifier
        if let script = language.script, language.languageCode == .chinese { id += "-\(script.identifier)" }
        return Locale(identifier: "en").localizedString(forIdentifier: id) ?? id
    }

    private static func detectLanguage(_ text: String) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }
}
