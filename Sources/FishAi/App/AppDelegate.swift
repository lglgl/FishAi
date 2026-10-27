import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var screenshotItem: NSMenuItem!
    private var clipboardItem: NSMenuItem!
    private var selectionItem: NSMenuItem!
    private var hotKeys: [HotKey] = []
    private var cancellables = Set<AnyCancellable>()
    private let settings = AppSettings.shared
    private let panel = ResultPanelController()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        registerHotKeys()
        // @Published 在赋值前发出通知，延后一拍再读取新值
        settings.$screenshotShortcut.map { _ in () }
            .merge(with: settings.$clipboardShortcut.map { _ in () },
                   settings.$selectionShortcut.map { _ in () },
                   settings.$isRecordingShortcut.map { _ in () })
            .dropFirst(4)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.registerHotKeys() }
            .store(in: &cancellables)

        // 调试用：--image <path> 跳过截图直接识别翻译该图片；--clipboard / --selection 等同于按下对应快捷键
        // （--selection 需配合 open -g 启动，让选中文字的应用留在前台）
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--image"), i + 1 < args.count,
           let image = NSImage(contentsOfFile: args[i + 1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            Task { await recognizeAndTranslate(image, origin: .screenshot) }
        } else if args.contains("--clipboard") {
            clipboardTranslate()
        } else if args.contains("--selection") {
            selectionTranslate()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // 菜单栏小鱼来自 .app 的 Resources；直接 swift run 时没有该资源，退回系统符号
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        statusItem.button?.image = icon ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "FishAi")

        let menu = NSMenu()
        screenshotItem = NSMenuItem(title: "截图翻译", action: #selector(screenshotTranslate), keyEquivalent: "")
        screenshotItem.target = self
        menu.addItem(screenshotItem)
        selectionItem = NSMenuItem(title: "划词翻译", action: #selector(selectionTranslate), keyEquivalent: "")
        selectionItem.target = self
        menu.addItem(selectionItem)
        clipboardItem = NSMenuItem(title: "剪贴板翻译", action: #selector(clipboardTranslate), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    /// 菜单栏应用不显示主菜单，但需要它来响应 ⌘C/⌘V/⌘W 等快捷键
    private func setupMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let mainMenu = NSMenu()
        for submenu in [appMenu, editMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    /// 按当前设置重新注册全局快捷键，并同步到菜单项
    private func registerHotKeys() {
        hotKeys.removeAll() // 释放时自动注销
        var conflicts = Set<AppSettings.ShortcutAction>()
        let bindings: [(AppSettings.ShortcutAction, Shortcut?, NSMenuItem, () -> Void)] = [
            (.screenshot, settings.screenshotShortcut, screenshotItem, { [weak self] in self?.screenshotTranslate() }),
            (.selection, settings.selectionShortcut, selectionItem, { [weak self] in self?.selectionTranslate() }),
            (.clipboard, settings.clipboardShortcut, clipboardItem, { [weak self] in self?.clipboardTranslate() }),
        ]
        for (action, shortcut, item, handler) in bindings {
            item.keyEquivalent = shortcut?.menuKeyEquivalent?.0 ?? ""
            item.keyEquivalentModifierMask = shortcut?.menuKeyEquivalent?.1 ?? []
            guard let shortcut, !settings.isRecordingShortcut else { continue }
            if let hotKey = HotKey(shortcut, handler: handler) {
                hotKeys.append(hotKey)
            } else {
                conflicts.insert(action)
            }
        }
        if !settings.isRecordingShortcut { settings.shortcutConflicts = conflicts }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            // 直接用 NSHostingView 承载，窗口大小取 SettingsView 的固定尺寸
            let hosting = NSHostingView(rootView: SettingsView())
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = hosting
            window.title = "FishAi 设置"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func screenshotTranslate() {
        guard ScreenCapture.ensurePermission() else { return }
        TextRecognizer.prewarm()
        Task { @MainActor in
            guard let image = await ScreenCapture.captureInteractively() else { return }
            await recognizeAndTranslate(image, origin: .screenshot)
        }
    }

    /// 划词翻译：将前台选中的文字先复制到系统剪贴板，再填入翻译框进行解析与翻译
    @objc func selectionTranslate() {
        guard SelectionReader.ensurePermission() else {
            perfLog.notice("selection: accessibility not trusted")
            panel.show()
            panel.model.beginRecognizing(origin: .selection)
            panel.model.fail("划词翻译需要「辅助功能」权限：在「系统设置 → 隐私与安全性 → 辅助功能」中打开 FishAi 后重试。若已打开仍不行，先移除 FishAi 再重新添加。")
            return
        }
        Task { @MainActor in
            // 必须先读选中文字再显示面板：面板会激活 FishAi，焦点和模拟的 ⌘C 都会落到面板上
            let text = await SelectionReader.copyAndGetSelectedText()
            panel.show()
            panel.model.beginRecognizing(origin: .selection)
            if let text {
                // 确保选中文本已复制到系统剪贴板
                SelectionReader.copyToPasteboard(text)
                // 发送给翻译框输入并触发解析/翻译
                panel.model.setSource(text, origin: .selection)
            } else {
                panel.model.fail("未检测到选中文本，请先选中需要翻译的内容")
            }
        }
    }

    /// 翻译剪贴板内容：优先取文字，没有文字时识别剪贴板中的图片
    @objc func clipboardTranslate() {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.show()
            panel.model.setSource(text, origin: .clipboard)
        } else if let image = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            Task { await recognizeAndTranslate(cgImage, origin: .clipboard) }
        } else {
            panel.show()
            panel.model.beginRecognizing(origin: .clipboard)
            panel.model.fail("剪贴板中没有文字或图片")
        }
    }

    /// 使用本地 Vision OCR 识别图像文字，完成后填入翻译框并触发大模型翻译
    private func recognizeAndTranslate(_ image: CGImage, origin: TranslationRecord.Origin) async {
        panel.show()
        panel.model.beginRecognizing(origin: origin)
        do {
            let text = try await TextRecognizer.recognize(image)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                panel.model.fail("本地 OCR 未识别到文字，请重新截取清晰文字区域")
            } else {
                if origin == .screenshot && settings.copyRecognizedText {
                    SelectionReader.copyToPasteboard(trimmed)
                }
                panel.model.setSource(trimmed, origin: origin)
            }
        } catch {
            panel.model.fail("本地 OCR 识别失败：\(error.localizedDescription)")
        }
    }
}
