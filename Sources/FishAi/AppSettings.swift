import Foundation
import Security

/// 用户设置：普通项存 UserDefaults，API Key 存钥匙串
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
        static let baseURL = "openAIBaseURL"
        static let model = "openAIModel"
        static let systemPrompt = "openAISystemPrompt"
        static let userPrompt = "openAIUserPrompt"
        static let apiKeyAccount = "openai-api-key"
    }

    private let defaults = UserDefaults.standard

    @Published var systemEnabled: Bool { didSet { defaults.set(systemEnabled, forKey: Key.systemEnabled) } }
    @Published var openAIEnabled: Bool { didSet { defaults.set(openAIEnabled, forKey: Key.openAIEnabled) } }
    @Published var baseURL: String { didSet { defaults.set(baseURL, forKey: Key.baseURL) } }
    @Published var model: String { didSet { defaults.set(model, forKey: Key.model) } }
    @Published var systemPrompt: String { didSet { defaults.set(systemPrompt, forKey: Key.systemPrompt) } }
    @Published var userPrompt: String { didSet { defaults.set(userPrompt, forKey: Key.userPrompt) } }
    @Published var apiKey: String { didSet { Keychain.set(apiKey, account: Key.apiKeyAccount) } }

    private init() {
        defaults.register(defaults: [
            Key.systemEnabled: true,
            Key.openAIEnabled: false,
            Key.baseURL: Self.defaultBaseURL,
            Key.model: Self.defaultModel,
            Key.systemPrompt: Self.defaultSystemPrompt,
            Key.userPrompt: Self.defaultUserPrompt,
        ])
        systemEnabled = defaults.bool(forKey: Key.systemEnabled)
        openAIEnabled = defaults.bool(forKey: Key.openAIEnabled)
        baseURL = defaults.string(forKey: Key.baseURL) ?? Self.defaultBaseURL
        model = defaults.string(forKey: Key.model) ?? Self.defaultModel
        systemPrompt = defaults.string(forKey: Key.systemPrompt) ?? Self.defaultSystemPrompt
        userPrompt = defaults.string(forKey: Key.userPrompt) ?? Self.defaultUserPrompt
        apiKey = Keychain.get(account: Key.apiKeyAccount) ?? ""
    }

    func resetPrompts() {
        systemPrompt = Self.defaultSystemPrompt
        userPrompt = Self.defaultUserPrompt
    }

    var openAIConfig: OpenAIClient.Config {
        OpenAIClient.Config(baseURL: baseURL, apiKey: apiKey, model: model,
                            systemPrompt: systemPrompt, userPrompt: userPrompt)
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
