import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let panel = ResultPanelController()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupStatusItem()
        // ⌥S：截图翻译
        hotKey = HotKey(keyCode: HotKey.kVK_S, modifiers: HotKey.optionKey) { [weak self] in
            self?.screenshotTranslate()
        }
        // 调试用：FishAi --image <path> 跳过截图，直接识别并翻译该图片
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--image"), i + 1 < args.count,
           let image = NSImage(contentsOfFile: args[i + 1])?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            Task { await recognizeAndTranslate(image) }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "FishAi")

        let menu = NSMenu()
        let capture = NSMenuItem(title: "截图翻译", action: #selector(screenshotTranslate), keyEquivalent: "s")
        capture.keyEquivalentModifierMask = [.option]
        capture.target = self
        menu.addItem(capture)
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
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
