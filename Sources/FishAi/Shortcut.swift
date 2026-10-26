import AppKit
import Carbon.HIToolbox

/// 全局快捷键：Carbon 键码 + Carbon 修饰键
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// 按键显示名，如 "S"、"Space"、"F1"
    var key: String

    static let screenshotDefault = Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey), key: "S")
    static let clipboardDefault = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey), key: "V")

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    /// 用于菜单项显示；特殊键返回 nil
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags)? {
        guard key.count == 1 else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return (key.lowercased(), flags)
    }

    /// 从按键事件创建；必须包含 ⌘、⌥ 或 ⌃（F 键除外），否则返回 nil
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }

        let code = Int(event.keyCode)
        let functionKey = Self.functionKeys[code]
        guard functionKey != nil || mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }

        guard let name = functionKey ?? Self.specialKeys[code]
                ?? event.charactersIgnoringModifiers?.uppercased(), !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(code), modifiers: mods, key: name)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}
