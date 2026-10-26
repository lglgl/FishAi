import AppKit

enum ScreenCapture {
    /// 检查屏幕录制权限；未授权时触发系统授权请求，并引导用户去系统设置开启。
    @MainActor
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        // 首次调用会弹出系统授权框，并把 FishAi 加入「屏幕录制」列表
        if CGRequestScreenCaptureAccess() { return true }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中允许 FishAi，然后退出并重新打开 FishAi。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    /// 调用系统 screencapture 进行交互式区域选择，用户按 Esc 取消时返回 nil。
    static func captureInteractively() async -> CGImage? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fishai-capture-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i 交互选区  -x 不播放声音
        process.arguments = ["-i", "-x", url.path]

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume()
            }
        }

        guard let image = NSImage(contentsOf: url) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
