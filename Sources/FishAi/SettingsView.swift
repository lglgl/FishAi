import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            ModelsView()
                .tabItem { Label("模型", systemImage: "cpu") }
            PromptsView()
                .tabItem { Label("提示词", systemImage: "text.bubble") }
            HistoryView()
                .tabItem { Label("翻译记录", systemImage: "clock") }
        }
        .frame(width: 640, height: 600)
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

// MARK: - 模型管理

private struct ModelsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var selection: Int64?

    var body: some View {
        ManagerLayout(
            items: settings.models, title: { $0.name }, selection: $selection,
            onAdd: { settings.addModel() },
            onCopy: { id in settings.addModel(copying: settings.models.first { $0.id == id }) },
            onDelete: { settings.deleteModel(id: $0) }
        ) { id in
            ModelEditor(id: id).id(id)
        }
    }
}

private struct ModelEditor: View {
    let id: Int64
    @ObservedObject var settings = AppSettings.shared
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, running, success(String), failure(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: field(\.name))
                TextField("Base URL", text: field(\.baseURL), prompt: Text(AppSettings.defaultBaseURL))
                SecureField("API Key", text: Binding(get: { settings.apiKey(for: id) },
                                                     set: { settings.setAPIKey($0, for: id) }),
                            prompt: Text("sk-…"))
                TextField("模型", text: field(\.model), prompt: Text(AppSettings.defaultModel))
            } footer: {
                Text("兼容 OpenAI /chat/completions 的服务都可以，如 OpenAI、DeepSeek、智谱、Ollama。API Key 保存在系统钥匙串。")
                    .foregroundStyle(.secondary)
            }
            Section {
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
        }
        .formStyle(.grouped)
    }

    private func field(_ keyPath: WritableKeyPath<LLMModel, String>) -> Binding<String> {
        Binding(
            get: { settings.models.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                guard var model = settings.models.first(where: { $0.id == id }) else { return }
                model[keyPath: keyPath] = value
                settings.updateModel(model)
            }
        )
    }

    private func testConnection() {
        testState = .running
        // 用默认翻译提示词测试
        let config = settings.config(model: settings.models.first { $0.id == id }, prompt: nil)
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

// MARK: - 提示词管理

private struct PromptsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var selection: Int64?

    var body: some View {
        ManagerLayout(
            items: settings.prompts, title: { $0.name }, selection: $selection,
            onAdd: { settings.addPrompt() },
            onCopy: { id in settings.addPrompt(copying: settings.prompts.first { $0.id == id }) },
            onDelete: { settings.deletePrompt(id: $0) }
        ) { id in
            PromptEditor(id: id).id(id)
        }
    }
}

private struct PromptEditor: View {
    let id: Int64
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                TextField("名称", text: field(\.name))
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("系统提示词")
                    TextEditor(text: field(\.systemPrompt))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 140)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("用户提示词")
                    TextEditor(text: field(\.userPrompt))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 70)
                }
            } footer: {
                Text("可用变量：{from} 源语言，{to} 目标语言，{text} 原文。翻译面板中可随时切换提示词，用来翻译、解释、润色或提问。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func field(_ keyPath: WritableKeyPath<PromptTemplate, String>) -> Binding<String> {
        Binding(
            get: { settings.prompts.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                guard var prompt = settings.prompts.first(where: { $0.id == id }) else { return }
                prompt[keyPath: keyPath] = value
                settings.updatePrompt(prompt)
            }
        )
    }
}

/// 左侧列表（新建 / 复制 / 删除）+ 右侧编辑区
private struct ManagerLayout<Item: Identifiable, Detail: View>: View where Item.ID == Int64 {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Int64?
    let onAdd: () -> Int64
    let onCopy: (Int64) -> Int64
    let onDelete: (Int64) -> Void
    @ViewBuilder let detail: (Int64) -> Detail

    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(items) { item in
                        Text(title(item).isEmpty ? "未命名" : title(item)).tag(item.id)
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Button { selection = onAdd() } label: { Image(systemName: "plus").frame(width: 22, height: 22) }
                        .help("新建")
                    Button { confirmDelete = true } label: { Image(systemName: "minus").frame(width: 22, height: 22) }
                        .help("删除")
                        .disabled(selection == nil || items.count <= 1)
                    Button {
                        if let selection { self.selection = onCopy(selection) }
                    } label: { Image(systemName: "doc.on.doc").frame(width: 22, height: 22) }
                        .help("复制")
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 180)

            Divider()

            if let selection, items.contains(where: { $0.id == selection }) {
                detail(selection)
            } else {
                Text("在左侧选择一项")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = items.first?.id } }
        .confirmationDialog("删除「\(items.first { $0.id == selection }.map(title) ?? "")」？",
                            isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                guard let selection else { return }
                onDelete(selection)
                self.selection = items.first { $0.id != selection }?.id
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
