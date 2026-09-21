import AppKit
import SwiftUI

@MainActor
final class WindowCoordinator {
    static let mainPanelWidth: CGFloat = 336
    static let mainPanelMinimumHeight: CGFloat = 106
    static let mainPanelMaximumHeight: CGFloat = 560
    static let homeWindowDefaultSize = NSSize(width: 400, height: 720)
    static let homeWindowMinimumSize = NSSize(width: 380, height: 520)
    static let homeWindowAutosaveName = "MonoList.HomeWindow.CompactV3"

    static var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
            "MonoList"
    }

    static func requiresScrolling(contentHeight: CGFloat) -> Bool {
        true
    }

    static func mainPanelAnchor(
        below statusItemFrame: NSRect,
        in visibleFrame: NSRect
    ) -> NSPoint {
        NSPoint(x: statusItemFrame.midX, y: visibleFrame.maxY)
    }

    static func isStatusItemClick(_ point: NSPoint, frame: NSRect?) -> Bool {
        frame?.insetBy(dx: -2, dy: -2).contains(point) == true
    }

    static func shouldCloseMainPanel(
        clickedWindow: NSWindow?,
        mainPanel: NSWindow,
        homeWindow: NSWindow?
    ) -> Bool {
        clickedWindow !== mainPanel && clickedWindow === homeWindow
    }

    static func fallbackMainPanelAnchor(
        in screenFrame: NSRect,
        menuBarBottomY: CGFloat
    ) -> NSPoint {
        NSPoint(
            x: screenFrame.maxX - mainPanelWidth / 2 - 8,
            y: menuBarBottomY
        )
    }

    var onWillShowMainPanel: (() -> Void)?

    private let taskStore: TaskStore
    private let draftState = TaskDraftState()
    private var mainPanel: MainPanel?
    private var globalOutsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    private var mainPanelResizeTimer: Timer?
    private var pendingResizeWorkItem: DispatchWorkItem?
    private weak var previousApplication: NSRunningApplication?
    private var homeWindow: NSWindow?
    private let homePresentationState = HomePresentationState()
    private var settings: AppSettings?
    private var reminderScheduler: ReminderScheduler?
    private var loginItemController: LoginItemController?
    private var updater: AppUpdater?
    private var onInstallUpdate: ((AppUpdate) -> Void)?
    private var onTestReminder: (() -> Void)?
    private var menuBarAnchor: NSPoint?
    private var menuBarButtonFrame: NSRect?

    var isMainPanelVisible: Bool {
        mainPanel?.isVisible == true
    }

    var isSettingsVisible: Bool {
        homeWindow?.isVisible == true && homePresentationState.section == .settings
    }

    var isHomeVisible: Bool {
        homeWindow?.isVisible == true
    }

    init(taskStore: TaskStore) {
        self.taskStore = taskStore
    }

    static func preferredMainPanelHeight(
        pendingCount: Int,
        todayCompletedCount: Int,
        olderVisibleCount: Int
    ) -> CGFloat {
        let rowCount = pendingCount + todayCompletedCount + olderVisibleCount
        let height: CGFloat = 106 + CGFloat(rowCount) * 36
        return min(max(height, mainPanelMinimumHeight), mainPanelMaximumHeight)
    }

    static func mainPanelFrame(
        keepingTopOf frame: NSRect,
        height: CGFloat
    ) -> NSRect {
        NSRect(
            x: frame.minX,
            y: frame.maxY - height,
            width: frame.width,
            height: height
        )
    }

    static func interpolatedMainPanelFrame(
        from start: NSRect,
        to end: NSRect,
        progress: CGFloat
    ) -> NSRect {
        let value = min(max(progress, 0), 1)
        func interpolate(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
            start + (end - start) * value
        }
        let height = interpolate(start.height, end.height)
        return NSRect(
            x: interpolate(start.minX, end.minX),
            y: start.maxY - height,
            width: interpolate(start.width, end.width),
            height: height
        )
    }

    func configureSettings(
        settings: AppSettings,
        reminderScheduler: ReminderScheduler,
        loginItemController: LoginItemController,
        updater: AppUpdater,
        onInstallUpdate: @escaping (AppUpdate) -> Void,
        onTestReminder: @escaping () -> Void
    ) {
        self.settings = settings
        self.reminderScheduler = reminderScheduler
        self.loginItemController = loginItemController
        self.updater = updater
        self.onInstallUpdate = onInstallUpdate
        self.onTestReminder = onTestReminder
    }

    func toggleMainPanel(relativeTo button: NSStatusBarButton) {
        if isMainPanelVisible {
            closeMainPanel(restoringFocus: true)
            return
        }

        showMainPanel(relativeTo: button)
    }

    func toggleMainPanel(at anchor: NSPoint) {
        if isMainPanelVisible {
            closeMainPanel(restoringFocus: true)
            return
        }
        showMainPanel(at: anchor)
    }

    func updateMenuBarLocation(anchor: NSPoint, buttonFrame: NSRect) {
        menuBarAnchor = anchor
        menuBarButtonFrame = buttonFrame
    }

    func toggleMainPanelFromDock() {
        if let menuBarAnchor {
            toggleMainPanel(at: menuBarAnchor)
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        toggleMainPanel(
            at: Self.fallbackMainPanelAnchor(
                in: screen.frame,
                menuBarBottomY: screen.visibleFrame.maxY
            )
        )
    }

    func showOrFocusMainPanelFromMenuBar() {
        if let menuBarAnchor {
            showOrFocusMainPanel(at: menuBarAnchor)
            return
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        showOrFocusMainPanel(
            at: Self.fallbackMainPanelAnchor(
                in: screen.frame,
                menuBarBottomY: screen.visibleFrame.maxY
            )
        )
    }

    func showOrFocusMainPanel(relativeTo button: NSStatusBarButton) {
        if let mainPanel, mainPanel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            mainPanel.makeKeyAndOrderFront(nil)
            mainPanel.orderFrontRegardless()
            return
        }
        showMainPanel(relativeTo: button)
    }

    func showOrFocusMainPanel(at anchor: NSPoint) {
        if let mainPanel, mainPanel.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            mainPanel.makeKeyAndOrderFront(nil)
            mainPanel.orderFrontRegardless()
            return
        }
        showMainPanel(at: anchor)
    }

    func showMainPanel(at anchor: NSPoint) {
        closeMainPanel(animated: false)
        onWillShowMainPanel?()
        rememberFrontmostApplication()
        draftState.syncVisibility(hasPendingTasks: !taskStore.pendingTasks.isEmpty)

        let panel = makeMainPanel()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let originX = min(
            max(anchor.x - Self.mainPanelWidth / 2, visibleFrame.minX + 8),
            visibleFrame.maxX - Self.mainPanelWidth - 8
        )
        let originY = max(
            visibleFrame.minY + 8,
            anchor.y - panel.frame.height
        )
        let finalFrame = NSRect(
            x: originX,
            y: originY,
            width: panel.frame.width,
            height: panel.frame.height
        )
        panel.setFrame(finalFrame, display: false)
        panel.alphaValue = 0
        mainPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.mainPanel === panel else { return }
            self.installOutsideClickMonitors(for: panel)
        }
    }

    func closeMainPanel(
        restoringFocus: Bool = false,
        animated: Bool = true
    ) {
        removeOutsideClickMonitor()
        if draftState.isPresented {
            try? draftState.commitOrDismiss(to: taskStore)
        }
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        mainPanelResizeTimer?.invalidate()
        mainPanelResizeTimer = nil
        let panel = mainPanel
        mainPanel = nil
        if animated, let panel, panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        } else {
            panel?.orderOut(nil)
        }

        if restoringFocus,
           let previousApplication,
           !previousApplication.isTerminated {
            previousApplication.activate(options: [])
        }
    }

    func showSettings() {
        showHome(showSettings: true)
    }

    func showHome(showSettings: Bool = false) {
        closeMainPanel()
        homePresentationState.section = showSettings ? .settings : .tasks
        guard let settingsValue = self.settings,
              let reminderScheduler,
              let loginItemController,
              let updater else {
            return
        }

        if let homeWindow {
            NSApp.activate(ignoringOtherApps: true)
            homeWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = HomeWindow(
            contentRect: NSRect(
                origin: .zero,
                size: Self.homeWindowDefaultSize
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.appDisplayName
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.isRestorable = true

        let hostingView = NSHostingView(
            rootView: HomeView(
                store: taskStore,
                presentation: homePresentationState,
                settings: settingsValue,
                reminderScheduler: reminderScheduler,
                loginItemController: loginItemController,
                updater: updater,
                onInstallUpdate: onInstallUpdate ?? { _ in },
                onTestReminder: onTestReminder ?? {},
                onWindowReady: { [weak window] in
                    DispatchQueue.main.async {
                        window?.contentMinSize = Self.homeWindowMinimumSize
                        window?.minSize = NSSize(
                            width: Self.homeWindowMinimumSize.width,
                            height: Self.homeWindowMinimumSize.height + 32
                        )
                    }
                }
            )
        )
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = NSRect(origin: .zero, size: Self.homeWindowDefaultSize)
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.contentMinSize = Self.homeWindowMinimumSize
        window.minSize = NSSize(
            width: Self.homeWindowMinimumSize.width,
            height: Self.homeWindowMinimumSize.height + 32
        )
        homeWindow = window

        let restoredFrame = window.setFrameUsingName(Self.homeWindowAutosaveName)
        window.setFrameAutosaveName(Self.homeWindowAutosaveName)
        if !restoredFrame {
            window.center()
        } else {
            let currentContentSize = window.contentRect(forFrameRect: window.frame).size
            if currentContentSize.width < Self.homeWindowDefaultSize.width ||
                currentContentSize.height < Self.homeWindowDefaultSize.height {
                window.setContentSize(
                    NSSize(
                        width: max(currentContentSize.width, Self.homeWindowDefaultSize.width),
                        height: max(currentContentSize.height, Self.homeWindowDefaultSize.height)
                    )
                )
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak window] in
            window?.contentMinSize = Self.homeWindowMinimumSize
            window?.minSize = NSSize(
                width: Self.homeWindowMinimumSize.width,
                height: Self.homeWindowMinimumSize.height + 32
            )
        }
    }

    private func makeMainPanel() -> MainPanel {
        weak var panelReference: MainPanel?
        let hostingView = MainPanelHostingView(
            rootView: TaskListView(
                store: taskStore,
                draftState: draftState,
                onOpenHome: { [weak self] in
                    self?.closeMainPanel()
                    self?.showHome()
                },
                onHeightChanged: { [weak self] height in
                    guard let self, let panel = panelReference else { return }
                    self.resizeMainPanel(panel, to: height)
                }
            )
        )
        let initialHeight = min(
            max(hostingView.fittingSize.height, Self.mainPanelMinimumHeight),
            Self.mainPanelMaximumHeight
        )
        hostingView.sizingOptions = []
        let panel = MainPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.mainPanelWidth,
                height: initialHeight
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panelReference = panel
        panel.canBecomeKeyOverride = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.onCancel = { [weak self] in
            self?.closeMainPanel(restoringFocus: true)
        }
        panel.contentView = hostingView
        return panel
    }

    private func resizeMainPanel(_ panel: NSPanel, to height: CGFloat) {
        let clampedHeight = min(
            max(height, Self.mainPanelMinimumHeight),
            Self.mainPanelMaximumHeight
        )
        pendingResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.mainPanel === panel else { return }
            self.performMainPanelResize(panel, to: clampedHeight)
        }
        pendingResizeWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func performMainPanelResize(_ panel: NSPanel, to height: CGFloat) {
        mainPanelResizeTimer?.invalidate()
        mainPanelResizeTimer = nil
        let currentFrame = panel.frame
        guard abs(currentFrame.height - height) > 0.5 else { return }
        let targetFrame = Self.mainPanelFrame(
            keepingTopOf: currentFrame,
            height: height
        )
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(targetFrame, display: true)
            return
        }
        let duration = 0.22
        let startTime = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) {
            [weak self, weak panel] timer in
            Task { @MainActor in
                guard let self,
                      let panel,
                      self.mainPanel === panel,
                      self.mainPanelResizeTimer === timer else {
                    timer.invalidate()
                    return
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - startTime
                let linearProgress = min(max(elapsed / duration, 0), 1)
                let easedProgress = linearProgress * linearProgress *
                    (3 - 2 * linearProgress)
                let frame = Self.interpolatedMainPanelFrame(
                    from: currentFrame,
                    to: targetFrame,
                    progress: easedProgress
                )
                panel.setFrame(frame, display: true)
                if linearProgress >= 1 {
                    timer.invalidate()
                    self.mainPanelResizeTimer = nil
                }
            }
        }
        mainPanelResizeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func showMainPanel(relativeTo button: NSStatusBarButton) {
        if let buttonWindow = button.window {
            let buttonFrame = buttonWindow.convertToScreen(button.frame)
            if let screen = NSScreen.screens.first(
                where: {
                    $0.frame.intersects(buttonFrame) &&
                        buttonFrame.midX > $0.frame.midX
                }
            ) {
                showMainPanel(
                    at: NSPoint(
                        x: buttonFrame.midX,
                        y: screen.frame.maxY -
                            NSStatusBar.system.thickness
                    )
                )
                return
            }
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        showMainPanel(
            at: Self.fallbackMainPanelAnchor(
                in: screen.frame,
                menuBarBottomY: screen.visibleFrame.maxY
            )
        )
    }

    private func rememberFrontmostApplication() {
        let current = NSWorkspace.shared.frontmostApplication
        if current?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = current
        }
    }

    private func installOutsideClickMonitors(for panel: NSPanel) {
        removeOutsideClickMonitor()
        globalOutsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            let clickPoint = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self else { return }
                if Self.isStatusItemClick(
                    clickPoint,
                    frame: self.menuBarButtonFrame
                ) {
                    return
                }
                self.closeMainPanel()
            }
        }
        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self, weak panel] event in
            guard let self, let panel else { return event }
            if Self.shouldCloseMainPanel(
                clickedWindow: event.window,
                mainPanel: panel,
                homeWindow: self.homeWindow
            ) {
                self.closeMainPanel()
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let globalOutsideClickMonitor {
            NSEvent.removeMonitor(globalOutsideClickMonitor)
            self.globalOutsideClickMonitor = nil
        }
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
    }
}

private final class MainPanel: NSPanel {
    var canBecomeKeyOverride = false
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool {
        canBecomeKeyOverride
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           let editor = firstResponder as? NSTextView,
           let contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            if let hitView = contentView.hitTest(point),
               hitView !== editor,
               !hitView.isDescendant(of: editor) {
                makeFirstResponder(nil)
            }
        }
        super.sendEvent(event)
    }

    override func constrainFrameRect(
        _ frameRect: NSRect,
        to screen: NSScreen?
    ) -> NSRect {
        frameRect
    }
}

private final class HomeWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           let editor = firstResponder as? NSTextView,
           let contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            if let hitView = contentView.hitTest(point),
               hitView !== editor,
               !hitView.isDescendant(of: editor) {
                makeFirstResponder(nil)
            }
        }
        super.sendEvent(event)
    }
}

private final class MainPanelHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool {
        false
    }
}
