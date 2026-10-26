import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, running, success(String), failure(String)
    }

    var body: some View {
        Form {
            Section("翻译服务") {
                Toggle("系统翻译（离线）", isOn: $settings.systemEnabled)
                Toggle("OpenAI 兼容接口", isOn: $settings.openAIEnabled)
            }

            Section("OpenAI 兼容接口") {
                TextField("Base URL", text: $settings.baseURL, prompt: Text(AppSettings.defaultBaseURL))
                SecureField("API Key", text: $settings.apiKey, prompt: Text("sk-…"))
                TextField("模型", text: $settings.model, prompt: Text(AppSettings.defaultModel))
                HStack {
                    Button("测试连接", action: testConnection)
                        .disabled(testState == .running)
                    switch testState {
                    case .idle:
                        EmptyView()
                    case .running:
                        ProgressView().controlSize(.small)
                    case .success(let text):
                        Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
                .lineLimit(2)
            }

            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("系统提示词")
                    TextEditor(text: $settings.systemPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 90)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("用户提示词")
                    TextEditor(text: $settings.userPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 50)
                }
                Button("恢复默认提示词") { settings.resetPrompts() }
            } header: {
                Text("提示词")
            } footer: {
                Text("可用变量：{from} 源语言，{to} 目标语言，{text} 原文")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 600)
    }

    private func testConnection() {
        testState = .running
        let config = settings.openAIConfig
        Task {
            var output = ""
            do {
                try await OpenAIClient.translate(
                    "Hello, world!", from: "English", to: "Chinese, Simplified", config: config
                ) { output += $0 }
                testState = .success(output.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
