import Foundation
import Security

/// 用户设置：开关、快捷键与当前选择存 UserDefaults，模型与提示词存 SQLite，API Key 存钥匙串
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-4o-mini"
    static let defaultSystemPrompt = """
        你是一名资深专业同声传译与本地化翻译专家。请将用户提供的文本从 {from} 准确、自然、流畅地翻译为 {to}。
        要求：
        1. 忠实原文：准确传达原意，符合目标语言的母语表达习惯，避免机翻感和生硬直译。
        2. 专业术语：保持专业技术术语、专有名词、代码标识符、缩写和专有格式的准确性。
        3. 排版格式：严格保留原文的段落结构、换行格式、缩进以及特殊符号。
        4. 纯净输出：仅输出翻译后的最终文本，严禁包含任何前缀、解释说明、反问、引号或额外元信息。
        """
    static let defaultUserPrompt = "{text}"

    /// 预置的高质量中文提示词模板
    static let builtinPrompts: [PromptTemplate] = [
        PromptTemplate(id: 0, name: "通用翻译", systemPrompt: defaultSystemPrompt, userPrompt: defaultUserPrompt),
        PromptTemplate(id: 0, name: "深入解析", systemPrompt: """
            你是一名精通多语言对比与语言教学的专家助手。请使用 {to} 对用户提供的文本进行精炼深入的解析：
            1. 核心意涵：用简练的语言概括句子或段落的主旨意义与语境。
            2. 重点词汇/短语：提取关键生词、俚语、行业术语或固定搭配，标注词性及常见含义。
            3. 语法/句式剖析：简析复杂长难句结构、特殊句式或易混淆语法点（如适用）。
            4. 语境/文化背景：若包含特定文化隐喻、行业行话或背景知识，作简明补充。
            排版清晰条理，便于快速阅读。
            """, userPrompt: defaultUserPrompt),
        PromptTemplate(id: 0, name: "文本润色", systemPrompt: """
            你是一名母语级资深文字编辑与写作导师。请对用户提供的原文进行深度润色与修饰：
            1. 语言表达：消除语病，增强用词的精准度、得体性与地道感，提升语句节奏感与文采。
            2. 逻辑流畅：理顺句间衔接，使行文更加清晰通顺，符合地道自然的表达习惯。
            3. 保持原意：严格忠于作者的原意与核心观点，不凭空增删事实。
            4. 输出要求：仅输出润色后的文本，不添加前后说明或额外解释。
            """, userPrompt: defaultUserPrompt),
        PromptTemplate(id: 0, name: "总结摘要", systemPrompt: """
            你是一名高效的信息分析与摘要专家。请使用 {to} 对用户提供的文本进行结构化提炼：
            1. 一句话结论：用最凝练的一句话概括核心结论或主旨。
            2. 核心要点：提炼 3~5 个关键要点，采用无序列表清晰呈现。
            3. 关键数据/行动项：若有明确的数据指标、结论或后续行动项，单独列出。
            要求精炼准确，去除冗余修饰，保持客观中立。
            """, userPrompt: defaultUserPrompt),
    ]

    private enum Key {
        static let historyEnabled = "historyEnabled"
        static let copyRecognizedText = "copyRecognizedText"
        static let selectedModelID = "selectedModelID"
        static let selectedPromptID = "selectedPromptID"
        static let builtinPromptsSeeded = "builtinPromptsSeeded"
        static let systemModelDefaulted = "systemModelDefaulted"
        static let screenshotShortcut = "screenshotShortcut"
        static let clipboardShortcut = "clipboardShortcut"
        static let selectionShortcut = "selectionShortcut"
        // 旧版存在 UserDefaults / 钥匙串中的单组配置，首次启动时迁移到数据库
        static let legacyBaseURL = "openAIBaseURL"
        static let legacyModel = "openAIModel"
        static let legacySystemPrompt = "openAISystemPrompt"
        static let legacyUserPrompt = "openAIUserPrompt"
        static let legacyAPIKeyAccount = "openai-api-key"
    }

    enum ShortcutAction: String {
        case screenshot, clipboard, selection
    }

    private let defaults = UserDefaults.standard
    private let db = Database.shared

    @Published var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) } }
    /// 截图识别出的文字自动写入剪贴板
    @Published var copyRecognizedText: Bool {
        didSet { defaults.set(copyRecognizedText, forKey: Key.copyRecognizedText) }
    }
    /// nil 表示未设置快捷键
    @Published var screenshotShortcut: Shortcut? { didSet { save(screenshotShortcut, forKey: Key.screenshotShortcut) } }
    @Published var clipboardShortcut: Shortcut? { didSet { save(clipboardShortcut, forKey: Key.clipboardShortcut) } }
    @Published var selectionShortcut: Shortcut? { didSet { save(selectionShortcut, forKey: Key.selectionShortcut) } }

    /// 录制快捷键期间暂停全局快捷键，避免按下已注册的组合键时触发功能
    @Published var isRecordingShortcut = false
    /// 注册失败（被占用）的快捷键
    @Published var shortcutConflicts: Set<ShortcutAction> = []

    /// 全部模型（第一个是内置的系统翻译）与提示词（至少保留一个）
    @Published private(set) var models: [LLMModel] = []
    @Published private(set) var prompts: [PromptTemplate] = []
    /// 翻译面板当前选择的模型与提示词
    @Published var selectedModelID: Int64? {
        didSet { defaults.set(selectedModelID.map(NSNumber.init(value:)), forKey: Key.selectedModelID) }
    }
    @Published var selectedPromptID: Int64? {
        didSet { defaults.set(selectedPromptID.map(NSNumber.init(value:)), forKey: Key.selectedPromptID) }
    }
    /// API Key 缓存，避免界面刷新时反复读钥匙串
    private var apiKeyCache: [Int64: String] = [:]

    private init() {
        defaults.register(defaults: [
            Key.historyEnabled: true,
        ])
        historyEnabled = defaults.bool(forKey: Key.historyEnabled)
        copyRecognizedText = defaults.bool(forKey: Key.copyRecognizedText)
        screenshotShortcut = Self.load(Key.screenshotShortcut, default: .screenshotDefault)
        clipboardShortcut = Self.load(Key.clipboardShortcut, default: .clipboardDefault)
        selectionShortcut = Self.load(Key.selectionShortcut, default: .selectionDefault)

        migrateLegacyConfigIfNeeded()
        // 预置提示词只补一次，用户删掉后不再出现
        if !defaults.bool(forKey: Key.builtinPromptsSeeded) {
            let existing = Set(db.fetchPrompts().map(\.name))
            Self.builtinPrompts.filter { !existing.contains($0.name) }.forEach { db.insertPrompt($0) }
            defaults.set(true, forKey: Key.builtinPromptsSeeded)
        }
        models = db.fetchModels()
        prompts = db.fetchPrompts()
        selectedModelID = Self.validID(defaults.object(forKey: Key.selectedModelID), in: models.map(\.id))
        // 还没选过提示词时默认用翻译提示词；已有的选择保持不变
        let translationPromptID = prompts.first { ["通用翻译", "翻译"].contains($0.name) }?.id
        selectedPromptID = Self.validID(defaults.object(forKey: Key.selectedPromptID), in: prompts.map(\.id),
                                        fallback: translationPromptID)
        // 系统翻译成为默认模型（只切换一次，之后尊重用户的选择）
        if !defaults.bool(forKey: Key.systemModelDefaulted) {
            selectedModelID = models.first(where: \.isSystem)?.id ?? selectedModelID
            defaults.set(true, forKey: Key.systemModelDefaulted)
        }
    }

    private static func validID(_ stored: Any?, in ids: [Int64], fallback: Int64? = nil) -> Int64? {
        if let id = (stored as? NSNumber)?.int64Value, ids.contains(id) { return id }
        return fallback ?? ids.first
    }

    // MARK: - 模型

    var selectedModel: LLMModel? { models.first { $0.id == selectedModelID } }
    var selectedPrompt: PromptTemplate? { prompts.first { $0.id == selectedPromptID } }

    /// 当前选择组合成的请求配置
    var openAIConfig: OpenAIClient.Config {
        config(model: selectedModel, prompt: selectedPrompt)
    }

    func config(model: LLMModel?, prompt: PromptTemplate?) -> OpenAIClient.Config {
        OpenAIClient.Config(
            baseURL: model?.baseURL ?? Self.defaultBaseURL,
            apiKey: model.map { apiKey(for: $0.id) } ?? "",
            model: model?.model ?? Self.defaultModel,
            systemPrompt: prompt?.systemPrompt ?? Self.defaultSystemPrompt,
            userPrompt: prompt?.userPrompt ?? Self.defaultUserPrompt)
    }

    @discardableResult
    func addModel(copying base: LLMModel? = nil) -> Int64 {
        let base = base?.isSystem == true ? nil : base
        var model = base ?? LLMModel(id: 0, name: "", baseURL: Self.defaultBaseURL, model: Self.defaultModel)
        model.name = base.map { "\($0.name) 副本" } ?? "新模型 \(models.count + 1)"
        model.id = db.insertModel(model)
        if let base { setAPIKey(apiKey(for: base.id), for: model.id) }
        models.append(model)
        return model.id
    }

    func updateModel(_ model: LLMModel) {
        guard let index = models.firstIndex(where: { $0.id == model.id }), models[index] != model else { return }
        models[index] = model
        db.updateModel(model)
    }

    func deleteModel(id: Int64) {
        guard models.contains(where: { $0.id == id && !$0.isSystem }) else { return }
        db.deleteModel(id: id)
        setAPIKey("", for: id)
        models.removeAll { $0.id == id }
        if selectedModelID == id { selectedModelID = models.first?.id }
    }

    func apiKey(for id: Int64) -> String {
        if let cached = apiKeyCache[id] { return cached }
        let key = Keychain.get(account: Self.apiKeyAccount(id)) ?? ""
        apiKeyCache[id] = key
        return key
    }

    func setAPIKey(_ key: String, for id: Int64) {
        guard apiKey(for: id) != key else { return }
        apiKeyCache[id] = key
        Keychain.set(key, account: Self.apiKeyAccount(id))
        objectWillChange.send()
    }

    // MARK: - 提示词

    @discardableResult
    func addPrompt(copying base: PromptTemplate? = nil) -> Int64 {
        var prompt = base ?? PromptTemplate(id: 0, name: "", systemPrompt: Self.defaultSystemPrompt,
                                            userPrompt: Self.defaultUserPrompt)
        prompt.name = base.map { "\($0.name) 副本" } ?? "新提示词 \(prompts.count + 1)"
        prompt.id = db.insertPrompt(prompt)
        prompts.append(prompt)
        return prompt.id
    }

    func updatePrompt(_ prompt: PromptTemplate) {
        guard let index = prompts.firstIndex(where: { $0.id == prompt.id }), prompts[index] != prompt else { return }
        prompts[index] = prompt
        db.updatePrompt(prompt)
    }

    func deletePrompt(id: Int64) {
        guard prompts.count > 1 else { return }
        db.deletePrompt(id: id)
        prompts.removeAll { $0.id == id }
        if selectedPromptID == id { selectedPromptID = prompts.first?.id }
    }

    /// 恢复/补充默认中文提示词模板
    func resetBuiltinPrompts() {
        for builtin in Self.builtinPrompts {
            if let existing = prompts.first(where: { $0.name == builtin.name }) {
                var updated = existing
                updated.systemPrompt = builtin.systemPrompt
                updated.userPrompt = builtin.userPrompt
                updatePrompt(updated)
            } else {
                addPrompt(copying: builtin)
            }
        }
        prompts = db.fetchPrompts()
    }

    private static func apiKeyAccount(_ id: Int64) -> String { "openai-api-key-\(id)" }

    /// 每步都可重复执行，中途被打断（如等待钥匙串授权时退出）下次启动会继续
    private func migrateLegacyConfigIfNeeded() {
        let hasLegacy = defaults.string(forKey: Key.legacyBaseURL) != nil || defaults.string(forKey: Key.legacyModel) != nil
        if hasLegacy, !db.fetchModels().contains(where: { !$0.isSystem }) {
            db.insertModel(LLMModel(
                id: 0, name: "默认",
                baseURL: defaults.string(forKey: Key.legacyBaseURL) ?? Self.defaultBaseURL,
                model: defaults.string(forKey: Key.legacyModel) ?? Self.defaultModel))
            if db.fetchPrompts().isEmpty, let system = defaults.string(forKey: Key.legacySystemPrompt) {
                db.insertPrompt(PromptTemplate(
                    id: 0, name: "翻译", systemPrompt: system,
                    userPrompt: defaults.string(forKey: Key.legacyUserPrompt) ?? Self.defaultUserPrompt))
            }
        }
        // systemEnabled / openAIEnabled：v3 起由所选模型决定使用哪种翻译，不再需要开关
        for key in [Key.legacyBaseURL, Key.legacyModel, Key.legacySystemPrompt, Key.legacyUserPrompt,
                    "systemEnabled", "openAIEnabled"] {
            defaults.removeObject(forKey: key)
        }
        // 旧 API Key 归到第一个大模型（该模型还没有 Key 时）
        if let key = Keychain.get(account: Key.legacyAPIKeyAccount),
           let id = db.fetchModels().first(where: { !$0.isSystem })?.id {
            if Keychain.get(account: Self.apiKeyAccount(id)) == nil {
                Keychain.set(key, account: Self.apiKeyAccount(id))
            }
            Keychain.set("", account: Key.legacyAPIKeyAccount)
        }
    }

    // MARK: - 快捷键

    private func save(_ shortcut: Shortcut?, forKey key: String) {
        // 存空 Data 表示用户主动清除，区别于从未设置
        defaults.set(shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    private static func load(_ key: String, default value: Shortcut) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return value }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }
}

private enum Keychain {
    private static let service = "com.lglgl.FishAi"

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
