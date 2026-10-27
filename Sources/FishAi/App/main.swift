import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // 菜单栏应用：不显示 Dock 图标
    app.setActivationPolicy(.accessory)
    app.run()
}
