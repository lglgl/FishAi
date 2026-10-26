import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            ModelSettingsView()
                .tabItem { Label("模型", systemImage: "sparkles") }
            HistoryView()
                .tabItem { Label("翻译记录", systemImage: "clock") }
        }
        .frame(width: 560, height: 640)
    }
}

// MARK: - 通用

private struct GeneralSettingsView: View {
    @ObservedObject var settings = AppSettings.shared

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

            Section {
                Toggle("保存翻译记录", isOn: $settings.historyEnabled)
            } footer: {
                Text("记录保存在本机 ~/Library/Application Support/FishAi/fishai.sqlite")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 模型配置

private struct ModelSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var testState: TestState = .idle
    @State private var confirmDelete = false

    private enum TestState: Equatable {
        case idle, running, success(String), failure(String)
    }

    var body: some View {
        Form {
            Section {
                Picker("当前配置", selection: $settings.activeConfigID) {
                    ForEach(settings.configs) { Text($0.name.isEmpty ? "未命名" : $0.name).tag(Optional($0.id)) }
                }
                HStack {
                    Button("新建") { settings.addConfig() }
                    Button("复制") { settings.addConfig(copying: settings.activeConfig) }
                    Spacer()
                    Button("删除", role: .destructive) { confirmDelete = true }
                        .disabled(settings.configs.count <= 1)
                }
            } header: {
                Text("模型配置")
            } footer: {
                Text("配置保存在本机 SQLite 数据库，API Key 单独保存在系统钥匙串。")
                    .foregroundStyle(.secondary)
            }

            Section("OpenAI 兼容接口") {
                TextField("名称", text: field(\.name))
                TextField("Base URL", text: field(\.baseURL), prompt: Text(AppSettings.defaultBaseURL))
                SecureField("API Key", text: Binding(get: { settings.activeAPIKey }, set: settings.setActiveAPIKey),
                            prompt: Text("sk-…"))
                TextField("模型", text: field(\.model), prompt: Text(AppSettings.defaultModel))
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
                    TextEditor(text: field(\.systemPrompt))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 90)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("用户提示词")
                    TextEditor(text: field(\.userPrompt))
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
        .onChange(of: settings.activeConfigID) { testState = .idle }
        .confirmationDialog("删除配置「\(settings.activeConfig?.name ?? "")」？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { settings.deleteActiveConfig() }
        }
    }

    private func field(_ keyPath: WritableKeyPath<ModelConfig, String>) -> Binding<String> {
        Binding(
            get: { settings.activeConfig?[keyPath: keyPath] ?? "" },
            set: { value in settings.updateActiveConfig { $0[keyPath: keyPath] = value } }
        )
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

// MARK: - 翻译记录

private struct HistoryView: View {
    @ObservedObject var store = HistoryStore.shared
    @State private var confirmClear = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索原文或译文", text: $store.search)
                    .textFieldStyle(.roundedBorder)
                Button("清空", role: .destructive) { confirmClear = true }
                    .disabled(store.records.isEmpty)
            }
            .padding(12)

            if store.records.isEmpty {
                Text(store.search.isEmpty ? "暂无翻译记录" : "没有匹配的记录")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.records) { record in
                    row(record)
                        .contextMenu {
                            Button("复制原文") { copyToPasteboard(record.sourceText) }
                            Button("复制译文") { copyToPasteboard(record.resultText) }
                            Divider()
                            Button("删除", role: .destructive) { store.delete(record) }
                        }
                }
            }
        }
        .onAppear { store.reload() }
        .confirmationDialog("清空全部翻译记录？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { store.clear() }
        }
    }

    private func row(_ record: TranslationRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: record.origin))
                Text(Self.dateFormatter.string(from: record.createdAt))
                Text("·")
                Text(record.service == "system" ? "系统翻译" : record.model ?? "OpenAI")
                Spacer()
                Text("\(record.sourceLang ?? "auto") → \(record.targetLang)")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Text(record.sourceText).lineLimit(2)
            Text(record.resultText).lineLimit(3).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }

    private static func symbol(for origin: TranslationRecord.Origin) -> String {
        switch origin {
        case .screenshot: "camera.viewfinder"
        case .selection: "text.cursor"
        case .clipboard: "doc.on.clipboard"
        case .manual: "keyboard"
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
