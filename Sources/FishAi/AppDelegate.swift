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

        // 调试用：--image <path> 跳过截图直接识别翻译该图片；--clipboard 等同于按下剪贴板翻译快捷键
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--image"), i + 1 < args.count,
           let image = NSImage(contentsOfFile: args[i + 1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            Task { await recognizeAndTranslate(image) }
        } else if args.contains("--clipboard") {
            clipboardTranslate()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "FishAi")

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
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "FishAi 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func screenshotTranslate() {
        guard ScreenCapture.ensurePermission() else { return }
        Task { @MainActor in
            guard let image = await ScreenCapture.captureInteractively() else { return }
            await recognizeAndTranslate(image)
        }
    }

    /// 翻译前台应用中选中的文字
    @objc func selectionTranslate() {
        guard SelectionReader.ensurePermission() else { return }
        Task { @MainActor in
            let text = await SelectionReader.selectedText()
            panel.show()
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                panel.model.setSource(text)
            } else {
                panel.model.beginRecognizing()
                panel.model.fail("未获取到选中的文字")
            }
        }
    }

    /// 翻译剪贴板内容：优先取文字，没有文字时识别剪贴板中的图片
    @objc func clipboardTranslate() {
        let pasteboard = NSPasteboard.general
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.show()
            panel.model.setSource(text)
        } else if let image = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            Task { await recognizeAndTranslate(cgImage) }
        } else {
            panel.show()
            panel.model.beginRecognizing()
            panel.model.fail("剪贴板中没有文字或图片")
        }
    }

    private func recognizeAndTranslate(_ image: CGImage) async {
        panel.show()
        panel.model.beginRecognizing()
        do {
            let text = try await TextRecognizer.recognize(image)
            panel.model.setSource(text)
        } catch {
            panel.model.fail("文字识别失败：\(error.localizedDescription)")
        }
    }
}
