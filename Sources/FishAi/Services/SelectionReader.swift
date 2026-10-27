import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 读取前台应用中选中的文字并同步至剪贴板：
/// 1. 优先通过系统辅助功能 API 读取，读取成功后显式复制到系统剪贴板；
/// 2. 若目标应用（如 Chrome、Electron 等）未暴露选中文本属性，通过模拟 ⌘C 将其写入剪贴板并读取；
/// 3. 最终剪贴板将确保持有当前选中的文字。
enum SelectionReader {
    /// 未授权时弹出系统授权提示
    static func ensurePermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 获取前台选中文本并确保留存在剪贴板中
    @MainActor
    static func copyAndGetSelectedText() async -> String? {
        // 1. 尝试通过辅助功能接口直接读取
        if let text = selectedTextViaAccessibility(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            perfLog.notice("selection: via accessibility, \(text.count) chars")
            // 复制到系统剪贴板
            copyToPasteboard(text)
            return text
        }

        // 2. 辅助功能无法直接获取时，模拟 ⌘C 复制
        if let text = await selectedTextViaCopy(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            perfLog.notice("selection: via ⌘C, \(text.count) chars")
            copyToPasteboard(text)
            return text
        }

        perfLog.notice("selection: nothing selected")
        return nil
    }

    /// 显式写入系统剪贴板，确保剪贴板持有该选中文本
    static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func selectedTextViaAccessibility() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    /// 部分应用（Chrome、Electron、Sublime 等）需通过模拟 ⌘C 获取选中文字，结果直接保留在剪贴板中
    @MainActor
    private static func selectedTextViaCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount

        // 等用户松开快捷键里的 ⌥/⌃/⇧（最多 400ms），否则目标应用可能收到 ⌥⌘C 之类的组合
        let held: CGEventFlags = [.maskAlternate, .maskControl, .maskShift, .maskCommand]
        for _ in 0..<16 where !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }
        postCommandC()
        // 轮询等待剪贴板更新（最多等待 500ms）
        for _ in 0..<20 where pasteboard.changeCount == changeCount {
            try? await Task.sleep(for: .milliseconds(25))
        }

        guard pasteboard.changeCount != changeCount else { return nil }
        return pasteboard.string(forType: .string)
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: keyDown)
            // 只带 ⌘，忽略用户仍按着的快捷键修饰键（如 ⌥ 或 ⌃）
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
