import AppKit

final class MenuBarHelperDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var parentProcessID: pid_t = 0
    private var parentMonitor: Timer?
    private var countObserver: NSObjectProtocol?
    private var lastReportedFrame: NSRect?

    func start() {
        parentProcessID = ProcessInfo.processInfo.arguments
            .dropFirst()
            .first
            .flatMap(Int32.init) ?? 0
        let count = ProcessInfo.processInfo.arguments
            .dropFirst(2)
            .first
            .flatMap(Int.init) ?? 0

        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        item.autosaveName = MenuBarBridgeProtocol.statusItemAutosaveName
        item.isVisible = true
        item.button?.image = MenuBarIconRenderer.makeImage()
        item.button?.imagePosition = .imageLeading
        item.button?.title = MenuBarBridgeProtocol.title(pendingCount: count)
        item.button?.toolTip = MenuBarBridgeProtocol.toolTip()
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        DispatchQueue.main.async { [weak self] in
            self?.reportStatusItemFrameIfNeeded()
        }
        countObserver = DistributedNotificationCenter.default().addObserver(
            forName: MenuBarBridgeProtocol.pendingCountChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let countNumber = notification.userInfo?["count"] as? NSNumber else {
                return
            }
            self?.statusItem?.button?.title =
                MenuBarBridgeProtocol.title(pendingCount: countNumber.intValue)
            self?.statusItem?.button?.toolTip = MenuBarBridgeProtocol.toolTip()
            DispatchQueue.main.async { [weak self] in
                self?.reportStatusItemFrameIfNeeded()
            }
        }

        parentMonitor = Timer.scheduledTimer(
            withTimeInterval: 0.2,
            repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            self.reportStatusItemFrameIfNeeded()
            if self.parentProcessID <= 0 || kill(self.parentProcessID, 0) != 0 {
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let countObserver {
            DistributedNotificationCenter.default().removeObserver(countObserver)
        }
    }

    @objc
    private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(
                withTitle: "打开控制台",
                action: #selector(openSettings),
                keyEquivalent: ","
            )
            menu.addItem(.separator())
            menu.addItem(
                withTitle: "退出应用",
                action: #selector(quitApplication),
                keyEquivalent: "q"
            )
            for item in menu.items {
                item.target = self
            }
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
            return
        }

        guard let window = sender.window else { return }
        let frame = window.convertToScreen(sender.frame)
        let screen = NSScreen.screens.first {
            $0.frame.intersects(frame)
        } ?? NSScreen.main
        DistributedNotificationCenter.default().postNotificationName(
            MenuBarBridgeProtocol.showMainPanel,
            object: nil,
            userInfo: [
                "x": frame.midX,
                "y": screen?.visibleFrame.maxY ?? frame.minY,
            ],
            deliverImmediately: true
        )
    }

    private func reportStatusItemFrameIfNeeded() {
        guard let button = statusItem?.button,
              let window = button.window else {
            return
        }
        let frame = window.convertToScreen(button.frame)
        guard frame != lastReportedFrame else { return }
        lastReportedFrame = frame
        let screen = NSScreen.screens.first {
            $0.frame.intersects(frame)
        } ?? NSScreen.main
        DistributedNotificationCenter.default().postNotificationName(
            MenuBarBridgeProtocol.statusItemFrameChanged,
            object: nil,
            userInfo: [
                "x": frame.minX,
                "y": frame.minY,
                "width": frame.width,
                "height": frame.height,
                "anchorX": frame.midX,
                "anchorY": screen?.visibleFrame.maxY ?? frame.minY,
            ],
            deliverImmediately: true
        )
    }

    @objc
    private func openSettings() {
        DistributedNotificationCenter.default().postNotificationName(
            MenuBarBridgeProtocol.openSettings,
            object: nil,
            deliverImmediately: true
        )
    }

    @objc
    private func quitApplication() {
        DistributedNotificationCenter.default().postNotificationName(
            MenuBarBridgeProtocol.quit,
            object: nil,
            deliverImmediately: true
        )
    }
}

let application = NSApplication.shared
let delegate = MenuBarHelperDelegate()
application.delegate = delegate
application.finishLaunching()
delegate.start()
withExtendedLifetime(delegate) {
    application.run()
}
