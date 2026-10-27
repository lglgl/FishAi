import AppKit
import SwiftUI
import Translation

struct ResultView: View {
    @ObservedObject var model: TranslatorModel
    @ObservedObject var settings = AppSettings.shared
    /// 原文区高度：0 表示随内容自动伸缩，拖动分隔条后记住手动设置的高度
    @AppStorage("sourceEditorHeight") private var sourceHeight: Double = 0
    @State private var measuredHeight: CGFloat = 40
    @State private var dragStartHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 4) {
            sourceCard
            splitHandle
            optionsBar
                .padding(.bottom, 6)
            ResultCard(result: model.result)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 4) // 内容已自动避开透明标题栏（红绿灯和固定按钮），这里只留一点间距
        .translationTask(model.configuration) { session in
            await model.run(session)
        }
    }

    // MARK: - 原文

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 隐藏的 Text 决定高度：随内容在 2～6 行之间伸缩，TextEditor 叠在上面铺满它
            Text(model.sourceText.isEmpty ? " " : model.sourceText)
                .font(.system(size: 14))
                .lineLimit(6)
                .frame(minHeight: 40, alignment: .top)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hidden()
                .frame(height: sourceHeight > 0 ? sourceHeight : nil, alignment: .top)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeight = $0 }
                .overlay {
                    TextEditor(text: $model.sourceText)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .scrollContentBackground(.hidden)
                }
                .overlay(alignment: .topLeading) {
                    if model.isRecognizing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在识别文字…").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13))
                        .padding(.leading, 5)
                    } else if let error = model.sourceError {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .padding(.leading, 5)
                    }
                }
            HStack(spacing: 4) {
                if !model.sourceText.isEmpty {
                    Text("\(model.sourceText.count) 字符")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                CopyButton(help: "复制原文") { model.sourceText }
                IconButton(symbol: "arrow.clockwise", help: "重新翻译 ⌘↩") { model.translate() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(8)
        .cardBackground()
    }

    // MARK: - 分隔条：拖动调整原文区与译文区的高度比例，双击恢复自动

    private var splitHandle: some View {
        ZStack {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 4)
            ResizeHandle {
                dragStartHeight = measuredHeight
            } onDrag: { delta in
                sourceHeight = Double(min(max(dragStartHeight + delta, 40), 480))
            } onReset: {
                sourceHeight = 0
            }
        }
        .frame(height: 10)
        .help("拖动调整原文区高度，双击恢复自动高度")
    }

    // MARK: - 选项栏：语言 · 模型 · 提示词

    private var isSystem: Bool { settings.selectedModel?.isSystem ?? true }

    private var optionsBar: some View {
        HStack(spacing: 4) {
            Text(model.detectedSource.map(Self.displayName) ?? "自动检测")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            IconButton(symbol: "arrow.left.arrow.right", help: "互换语言：译文作为原文反向翻译") { model.swapLanguages() }
                .disabled(model.sourceText.isEmpty || model.isRecognizing)
            OptionMenu(title: model.target.name, help: "目标语言", selection: $model.target) {
                ForEach(TargetLanguage.all) { Text($0.name).tag($0) }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            OptionMenu(symbol: "cpu", title: Self.name(settings.selectedModel?.name),
                       help: "模型", selection: $settings.selectedModelID) {
                ForEach(settings.models) { Text(Self.name($0.name)).tag(Optional($0.id)) }
            }
            .layoutPriority(1)
            // 系统翻译不使用提示词；空间不够时提示词先截断
            OptionMenu(symbol: "text.bubble", title: Self.name(settings.selectedPrompt?.name),
                       help: isSystem ? "系统翻译不使用提示词" : "提示词", selection: $settings.selectedPromptID) {
                ForEach(settings.prompts) { Text(Self.name($0.name)).tag(Optional($0.id)) }
            }
            .disabled(isSystem)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 4)
        .onChange(of: settings.selectedModelID) { model.translate() }
        .onChange(of: settings.selectedPromptID) { if !isSystem { model.translate() } }
    }

    private static func name(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "未命名" }
        return name
    }

    private static func displayName(_ language: Locale.Language) -> String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        if code == "zh" {
            if let script = language.script?.identifier, script.contains("Hant") {
                return "繁体中文"
            }
            return "简体中文"
        }
        if let name = Locale(identifier: "zh-Hans").localizedString(forLanguageCode: code) {
            return name
        }
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// 译文卡片：无标题，流式输出时末尾带闪烁光标，复制按钮在右下角
private struct ResultCard: View {
    let result: TranslatorModel.ServiceResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                content
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                if result.phase == .loading {
                    ProgressView().controlSize(.mini)
                    Text("翻译中…").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                if result.phase == .done {
                    CopyButton(help: "复制译文") { result.text }
                }
            }
            .frame(height: 22)
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxHeight: .infinity, alignment: .top)
        .cardBackground(stroke: false)
    }

    @ViewBuilder private var content: some View {
        switch result.phase {
        case .failed(let message):
            Text(message).foregroundStyle(.red).textSelection(.enabled)
        case .loading:
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let visible = Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                Text(result.text) + Text("▍").foregroundColor(visible ? .accentColor : .clear)
            }
        default:
            Text(result.text.isEmpty ? " " : result.text).textSelection(.enabled)
        }
    }
}

/// 用 AppKit 处理拖动：面板可拖动背景移动窗口，SwiftUI 手势在这里会和移动窗口冲突
private struct ResizeHandle: NSViewRepresentable {
    let onBegin: () -> Void
    let onDrag: (CGFloat) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onReset = onReset
    }

    final class HandleView: NSView {
        var onBegin: () -> Void = {}
        var onDrag: (CGFloat) -> Void = { _ in }
        var onReset: () -> Void = {}
        private var startY: CGFloat = 0

        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onReset()
                return
            }
            startY = event.locationInWindow.y
            onBegin()
        }

        override func mouseDragged(with event: NSEvent) {
            // 窗口坐标 y 轴向上，向下拖动时原文区变高（拖动期间窗口不会移动）
            onDrag(startY - event.locationInWindow.y)
        }
    }
}

/// 复制按钮：点击后图标短暂变成 ✓
private struct CopyButton: View {
    let help: String
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            copy(text())
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.15)) { copied = false }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: copied ? .semibold : .regular))
                if copied { Text("已复制").font(.system(size: 11)) }
            }
            .frame(minWidth: 22, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        .help(help)
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// 选项栏里的紧凑下拉菜单：图标 + 当前值 + ⌄，名字过长时截断
private struct OptionMenu<Value: Hashable, Content: View>: View {
    var symbol: String?
    let title: String
    let help: String
    @Binding var selection: Value
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu {
            Picker(help, selection: $selection, content: content)
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovering = $0 }
        .help(help == title ? help : "\(help)：\(title)")
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private extension View {
    func cardBackground(stroke: Bool = true) -> some View {
        background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(stroke ? 1 : 0), lineWidth: 0.5)
        )
    }
}
