import AppKit
import SwiftUI
import Translation

struct ResultView: View {
    @ObservedObject var model: TranslatorModel
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 10) {
            sourceCard
            languageBar
            if settings.systemEnabled {
                ServiceCard(symbol: "apple.logo", title: "系统翻译", result: model.system)
            }
            if settings.openAIEnabled {
                ServiceCard(symbol: "sparkles", title: settings.model, result: model.openAI)
            }
            if !settings.systemEnabled && !settings.openAIEnabled {
                Text("请在设置中启用至少一个翻译服务")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .cardBackground()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 30) // 让出透明标题栏（红绿灯）的位置
        .translationTask(model.configuration) { session in
            await model.run(session)
        }
    }

    // MARK: - 原文

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.sourceText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 70, maxHeight: 140)
                if model.isRecognizing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在识别文字…").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .padding(.top, 2)
                    .padding(.leading, 5)
                } else if let error = model.sourceError {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .padding(.top, 2)
                        .padding(.leading, 5)
                }
            }
            HStack(spacing: 4) {
                Text(model.detectedSource.map(Self.displayName) ?? "自动检测")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: "doc.on.doc", help: "复制原文") { copy(model.sourceText) }
                IconButton(symbol: "arrow.clockwise", help: "重新翻译 ⌘↩") { model.translate() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(8)
        .cardBackground()
    }

    // MARK: - 语言栏

    private var languageBar: some View {
        HStack(spacing: 8) {
            Text(model.detectedSource.map(Self.displayName) ?? "自动检测")
                .frame(maxWidth: .infinity)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $model.target) {
                ForEach(TargetLanguage.all) { Text($0.name).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 12))
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .cardBackground()
    }

    private static func displayName(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.maximalIdentifier)
            ?? language.minimalIdentifier
    }
}

/// 单个翻译服务的结果卡片
private struct ServiceCard: View {
    let symbol: String
    let title: String
    let result: TranslatorModel.ServiceResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                if result.phase == .loading {
                    ProgressView().controlSize(.small)
                } else if result.phase == .done {
                    IconButton(symbol: "doc.on.doc", help: "复制译文") { copy(result.text) }
                }
            }
            .foregroundStyle(.secondary)

            ScrollView {
                Group {
                    if case .failed(let message) = result.phase {
                        Text(message).foregroundStyle(.red)
                    } else {
                        // 流式输出时边收边显示
                        Text(result.text.isEmpty ? " " : result.text).textSelection(.enabled)
                    }
                }
                .font(.system(size: 14))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .cardBackground()
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
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
    func cardBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
}
