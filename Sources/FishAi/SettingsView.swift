import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, running, success(String), failure(String)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("截图翻译") {
                    ShortcutRecorder(shortcut: $settings.screenshotShortcut, defaultValue: .screenshotDefault,
                                     conflict: settings.shortcutConflicts.contains(.screenshot))
                }
                LabeledContent("划词翻译") {
                    ShortcutRecorder(shortcut: $settings.selectionShortcut, defaultValue: .selectionDefault,
                                     conflict: settings.shortcutConflicts.contains(.selection))
                }
                LabeledContent("剪贴板翻译") {
                    ShortcutRecorder(shortcut: $settings.clipboardShortcut, defaultValue: .clipboardDefault,
                                     conflict: settings.shortcutConflicts.contains(.clipboard))
                }
            } header: {
                Text("快捷键")
            } footer: {
                Text("点击后按下组合键（需包含 ⌘、⌥ 或 ⌃），Esc 取消。划词翻译需要「辅助功能」权限。剪贴板翻译会翻译剪贴板中的文字，若是图片则先识别文字。")
                    .foregroundStyle(.secondary)
            }

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
        .frame(width: 500, height: 720)
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

/// 点击后录制下一次按键组合
private struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut?
    let defaultValue: Shortcut
    let conflict: Bool

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if conflict && !recording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("快捷键已被其他应用占用")
            }
            Button(action: toggleRecording) {
                Text(recording ? "按下快捷键…" : shortcut?.displayString ?? "未设置")
                    .frame(minWidth: 90)
            }
            Button {
                shortcut = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("清除")
            .disabled(shortcut == nil)
            Button {
                shortcut = defaultValue
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("恢复默认（\(defaultValue.displayString)）")
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        AppSettings.shared.isRecordingShortcut = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
            } else if let recorded = Shortcut(event: event) {
                shortcut = recorded
                stopRecording()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        AppSettings.shared.isRecordingShortcut = false
    }
}
