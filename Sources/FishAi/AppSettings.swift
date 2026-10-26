import Foundation
import Security

/// 用户设置：开关与快捷键存 UserDefaults，模型配置存 SQLite，API Key 存钥匙串
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModel = "gpt-4o-mini"
    static let defaultSystemPrompt = """
        You are a professional translation engine. Translate the user's text from {from} to {to}. \
        Output only the translation, without explanations, quotes or any extra content. \
        Preserve the original line breaks and formatting.
        """
    static let defaultUserPrompt = "{text}"

    private enum Key {
        static let systemEnabled = "systemEnabled"
        static let openAIEnabled = "openAIEnabled"
        static let historyEnabled = "historyEnabled"
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

    @Published var systemEnabled: Bool { didSet { defaults.set(systemEnabled, forKey: Key.systemEnabled) } }
    @Published var openAIEnabled: Bool { didSet { defaults.set(openAIEnabled, forKey: Key.openAIEnabled) } }
    @Published var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) } }
    /// nil 表示未设置快捷键
    @Published var screenshotShortcut: Shortcut? { didSet { save(screenshotShortcut, forKey: Key.screenshotShortcut) } }
    @Published var clipboardShortcut: Shortcut? { didSet { save(clipboardShortcut, forKey: Key.clipboardShortcut) } }
    @Published var selectionShortcut: Shortcut? { didSet { save(selectionShortcut, forKey: Key.selectionShortcut) } }

    /// 录制快捷键期间暂停全局快捷键，避免按下已注册的组合键时触发功能
    @Published var isRecordingShortcut = false
    /// 注册失败（被占用）的快捷键
    @Published var shortcutConflicts: Set<ShortcutAction> = []

    /// 全部模型配置，至少保留一组
    @Published private(set) var configs: [ModelConfig] = []
    @Published var activeConfigID: Int64? {
        didSet {
            guard let activeConfigID, activeConfigID != oldValue else { return }
            db.setActiveConfig(id: activeConfigID)
            activeAPIKey = Keychain.get(account: Self.apiKeyAccount(activeConfigID)) ?? ""
        }
    }
    /// 当前配置的 API Key（缓存，避免界面刷新时反复读钥匙串）
    @Published private(set) var activeAPIKey = ""

    private init() {
        defaults.register(defaults: [
            Key.systemEnabled: true,
            Key.openAIEnabled: false,
            Key.historyEnabled: true,
        ])
        systemEnabled = defaults.bool(forKey: Key.systemEnabled)
        openAIEnabled = defaults.bool(forKey: Key.openAIEnabled)
        historyEnabled = defaults.bool(forKey: Key.historyEnabled)
        screenshotShortcut = Self.load(Key.screenshotShortcut, default: .screenshotDefault)
        clipboardShortcut = Self.load(Key.clipboardShortcut, default: .clipboardDefault)
        selectionShortcut = Self.load(Key.selectionShortcut, default: .selectionDefault)

        migrateLegacyConfigIfNeeded()
        configs = db.fetchConfigs()
        let active = db.activeConfigID() ?? configs.first?.id
        activeConfigID = active
        if let active {
            db.setActiveConfig(id: active)
            activeAPIKey = Keychain.get(account: Self.apiKeyAccount(active)) ?? ""
        }
    }

    // MARK: - 模型配置

    var activeConfig: ModelConfig? {
        configs.first { $0.id == activeConfigID }
    }

    var openAIConfig: OpenAIClient.Config {
        let config = activeConfig
        return OpenAIClient.Config(
            baseURL: config?.baseURL ?? Self.defaultBaseURL, apiKey: activeAPIKey,
            model: config?.model ?? Self.defaultModel,
            systemPrompt: config?.systemPrompt ?? Self.defaultSystemPrompt,
            userPrompt: config?.userPrompt ?? Self.defaultUserPrompt)
    }

    func updateActiveConfig(_ change: (inout ModelConfig) -> Void) {
        guard let index = configs.firstIndex(where: { $0.id == activeConfigID }) else { return }
        change(&configs[index])
        db.updateConfig(configs[index])
    }

    func setActiveAPIKey(_ key: String) {
        guard let activeConfigID else { return }
        activeAPIKey = key
        Keychain.set(key, account: Self.apiKeyAccount(activeConfigID))
    }

    /// 新建配置；传入 base 时复制其内容和 API Key
    func addConfig(copying base: ModelConfig? = nil) {
        var config = base ?? ModelConfig(id: 0, name: "", baseURL: Self.defaultBaseURL, model: Self.defaultModel,
                                         systemPrompt: Self.defaultSystemPrompt, userPrompt: Self.defaultUserPrompt)
        config.name = base.map { "\($0.name) 副本" } ?? "新配置 \(configs.count + 1)"
        config.id = db.insertConfig(config)
        if let base, let key = Keychain.get(account: Self.apiKeyAccount(base.id)) {
            Keychain.set(key, account: Self.apiKeyAccount(config.id))
        }
        configs.append(config)
        activeConfigID = config.id
    }

    func deleteActiveConfig() {
        guard configs.count > 1, let id = activeConfigID else { return }
        db.deleteConfig(id: id)
        Keychain.set("", account: Self.apiKeyAccount(id))
        configs.removeAll { $0.id == id }
        activeConfigID = configs.first?.id
    }

    func resetPrompts() {
        updateActiveConfig {
            $0.systemPrompt = Self.defaultSystemPrompt
            $0.userPrompt = Self.defaultUserPrompt
        }
    }

    private static func apiKeyAccount(_ id: Int64) -> String { "openai-api-key-\(id)" }

    /// 每步都可重复执行，中途被打断（如等待钥匙串授权时退出）下次启动会继续
    private func migrateLegacyConfigIfNeeded() {
        if db.fetchConfigs().isEmpty {
            let config = ModelConfig(
                id: 0, name: "默认",
                baseURL: defaults.string(forKey: Key.legacyBaseURL) ?? Self.defaultBaseURL,
                model: defaults.string(forKey: Key.legacyModel) ?? Self.defaultModel,
                systemPrompt: defaults.string(forKey: Key.legacySystemPrompt) ?? Self.defaultSystemPrompt,
                userPrompt: defaults.string(forKey: Key.legacyUserPrompt) ?? Self.defaultUserPrompt)
            db.setActiveConfig(id: db.insertConfig(config))
        }
        for key in [Key.legacyBaseURL, Key.legacyModel, Key.legacySystemPrompt, Key.legacyUserPrompt] {
            defaults.removeObject(forKey: key)
        }
        // 旧 API Key 归到当前配置（该配置还没有 Key 时）
        if let key = Keychain.get(account: Key.legacyAPIKeyAccount),
           let id = db.activeConfigID() ?? db.fetchConfigs().first?.id {
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
