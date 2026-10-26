import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// 读取前台应用中选中的文字：优先用辅助功能接口，取不到时模拟 ⌘C 并还原剪贴板。
/// 两种方式都需要「辅助功能」权限。
enum SelectionReader {
    /// 未授权时弹出系统授权提示
    static func ensurePermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func selectedText() async -> String? {
        if let text = selectedTextViaAccessibility(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return await selectedTextViaCopy()
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

    /// 部分应用（Chrome、Electron 等）不支持读取选中文字，改为模拟复制
    @MainActor
    private static func selectedTextViaCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        let changeCount = pasteboard.changeCount

        postCommandC()
        for _ in 0..<20 where pasteboard.changeCount == changeCount {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard pasteboard.changeCount != changeCount else { return nil }
        let text = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
        return text
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: keyDown)
            // 只带 ⌘，忽略用户仍按着的快捷键修饰键（如 ⌥）
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
