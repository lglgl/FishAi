import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private let panel = ResultPanelController()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
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
