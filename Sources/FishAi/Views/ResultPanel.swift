import AppKit
import SwiftUI

/// 可成为 key window 的浮动面板，Esc 关闭
final class ResultPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// 未固定时，点击其他应用或切到其他应用即关闭面板；固定后常驻并保持位置
@MainActor
final class ResultPanelController: NSObject {
    let model = TranslatorModel()
    private lazy var panel: ResultPanel = makePanel()
    private var pinButton: NSButton!
    private var clickMonitor: Any?
    private var isPinned = false {
        didSet { updatePinButton() }
    }

    override init() {
        super.init()
        // 全局监听只会收到发往其他应用的点击，点本应用的窗口或菜单栏图标不会触发
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfUnpinned() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeIfUnpinned() }
        }
    }

    func show() {
        if !panel.isVisible { positionNearMouse() }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeIfUnpinned() {
        guard !isPinned, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    @objc private func togglePin() {
        isPinned.toggle()
    }

    private func updatePinButton() {
        let symbol = isPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: isPinned ? "取消固定" : "固定")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        pinButton.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
        pinButton.toolTip = isPinned ? "取消固定（点击别处时关闭）" : "固定窗口（点击别处时不关闭）"
    }

    private func makePinAccessory() -> NSTitlebarAccessoryViewController {
        pinButton = NSButton(image: NSImage(), target: self, action: #selector(togglePin))
        pinButton.isBordered = false
        pinButton.frame = NSRect(x: 0, y: 0, width: 28, height: 22)
        updatePinButton()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 28))
        pinButton.frame.origin = NSPoint(x: 2, y: 3)
        container.addSubview(pinButton)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .trailing
        return accessory
    }

    private func makePanel() -> ResultPanel {
        let panel = ResultPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 320, height: 300)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.addTitlebarAccessoryViewController(makePinAccessory())
        // 记住用户调整后的窗口大小（位置每次按鼠标重新计算）
        panel.setFrameAutosaveName("FishAiResultPanel")

        // 毛玻璃背景
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active

        let hosting = NSHostingView(rootView: ResultView(model: model))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: blur.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur
        return panel
    }

    private func positionNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}
