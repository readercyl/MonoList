import AppKit
import Combine
import SwiftUI

@MainActor
final class ReminderPanelController: ObservableObject {
    static let displayDurationSeconds: TimeInterval = 3
    static let dedicatedSoundRepeatCount = 3
    static let dedicatedSoundRepeatInterval: TimeInterval = 0.6

    @Published private(set) var isTesting = false
    private(set) var isDedicatedReminder = false

    private var panel: NSPanel?
    private var countdownTimer: Timer?
    private var soundRepeatTimer: Timer?
    private var remainingSoundRepeats = 0
    private var remainingTenths = Int(displayDurationSeconds * 10)
    private var model: ReminderPresentationModel?
    private var onClose: (() -> Void)?
    private var finalFrame: NSRect?
    private var isClosing = false
    private let playSound: (String) -> Void

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var currentPanelHeight: CGFloat? {
        panel?.frame.height
    }

    var currentPanelWidth: CGFloat? {
        panel?.frame.width
    }

    static func resolvedSoundName(_ preferredName: String) -> String {
        NSSound(named: NSSound.Name(preferredName)) == nil ? "Glass" : preferredName
    }

    init(
        playSound: @escaping (String) -> Void = { name in
            if let sound = NSSound(named: NSSound.Name(name)) {
                sound.stop()
                sound.play()
            } else {
                NSSound.beep()
            }
        }
    ) {
        self.playSound = playSound
    }

    static func tasksForTest(_ tasks: [TaskItem], at date: Date = Date()) -> [TaskItem] {
        guard tasks.isEmpty else { return tasks }
        return [
            TaskItem(
                id: UUID(),
                text: "这是一次轻提醒测试",
                status: .pending,
                order: 0,
                createdAt: date,
                updatedAt: date,
                completedAt: nil
            )
        ]
    }

    static func tasksForFocusTest(
        _ tasks: [TaskItem],
        at date: Date = Date()
    ) -> [TaskItem] {
        guard tasks.isEmpty else { return tasks }
        return [
            TaskItem(
                id: UUID(),
                text: "这是一次专注提醒测试",
                status: .pending,
                order: 0,
                createdAt: date,
                updatedAt: date,
                completedAt: nil
            )
        ]
    }

    func show(
        tasks: [TaskItem],
        position: ReminderPosition,
        menuBarButton: NSStatusBarButton?,
        title: String = "待办提醒",
        statusText: String? = nil,
        isFocusReminder: Bool = false,
        isDedicatedReminder: Bool = false,
        testing: Bool = false,
        playsSound: Bool = true,
        soundName: String = "Glass",
        onOpen: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        close(animated: false, notifying: false)
        guard !tasks.isEmpty else {
            onClose()
            return
        }

        let snapshot = Array(tasks.prefix(3))
        let panelWidth: CGFloat = isFocusReminder ? 420 : 340
        let model = ReminderPresentationModel()
        let hostingView = NSHostingView(
            rootView: ReminderView(
                title: title,
                statusText: statusText,
                isFocusReminder: isFocusReminder,
                totalCount: tasks.count,
                taskTexts: snapshot.map(\.text),
                model: model,
                onOpen: { [weak self] in
                    self?.close()
                    onOpen()
                },
                onClose: { [weak self] in
                    self?.close()
                }
            )
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: 0)
        hostingView.layoutSubtreeIfNeeded()
        let contentHeight = ceil(hostingView.fittingSize.height)
        let panel = PassiveReminderPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: contentHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.contentView = hostingView

        let mousePoint = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mousePoint) })
            ?? NSScreen.main
        guard let screen else {
            onClose()
            return
        }
        let frame = frame(
            size: panel.frame.size,
            position: position,
            visibleFrame: screen.visibleFrame,
            menuBarButton: menuBarButton
        )
        panel.setFrame(Self.presentationStartFrame(for: frame), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        self.panel = panel
        self.model = model
        self.onClose = onClose
        self.finalFrame = frame
        isTesting = testing
        self.isDedicatedReminder = isDedicatedReminder
        isClosing = false
        remainingTenths = Int(Self.displayDurationSeconds * 10)
        if playsSound {
            playReminderSound(
                name: Self.resolvedSoundName(soundName),
                repeatCount: isDedicatedReminder
                    ? Self.dedicatedSoundRepeatCount
                    : 1
            )
        }
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(frame, display: true)
            }
        }
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.countDown()
            }
        }
    }

    func close(animated: Bool = true, notifying: Bool = true) {
        stopSoundRepeats()
        guard let panel else {
            isTesting = false
            isDedicatedReminder = false
            if notifying {
                let callback = onClose
                onClose = nil
                callback?()
            } else {
                onClose = nil
            }
            return
        }
        if isClosing && animated {
            return
        }
        isClosing = true
        countdownTimer?.invalidate()
        countdownTimer = nil
        isTesting = false
        isDedicatedReminder = false

        guard animated, let finalFrame else {
            finishClosing(panel: panel, notifying: notifying)
            return
        }
        let targetFrame = Self.presentationStartFrame(for: finalFrame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self, weak panel] in
            Task { @MainActor in
                guard let self, let panel, self.panel === panel else { return }
                self.finishClosing(panel: panel, notifying: notifying)
            }
        }
    }

    private func playReminderSound(name: String, repeatCount: Int) {
        let count = max(0, repeatCount)
        guard count > 0 else { return }

        playSound(name)
        guard count > 1 else { return }

        remainingSoundRepeats = count - 1
        let timer = Timer(timeInterval: Self.dedicatedSoundRepeatInterval, repeats: true) {
            [weak self] timer in
            Task { @MainActor in
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard self.remainingSoundRepeats > 0 else {
                    self.stopSoundRepeats()
                    return
                }
                self.playSound(name)
                self.remainingSoundRepeats -= 1
                if self.remainingSoundRepeats == 0 {
                    self.stopSoundRepeats()
                }
            }
        }
        soundRepeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSoundRepeats() {
        soundRepeatTimer?.invalidate()
        soundRepeatTimer = nil
        remainingSoundRepeats = 0
    }

    static func presentationStartFrame(for finalFrame: NSRect) -> NSRect {
        return NSRect(
            x: finalFrame.minX,
            y: finalFrame.minY + 8,
            width: finalFrame.width,
            height: finalFrame.height
        )
    }

    private func countDown() {
        guard model?.isPaused == false else {
            return
        }
        remainingTenths -= 1
        model?.remainingSeconds = max(0, Int(ceil(Double(remainingTenths) / 10)))
        if remainingTenths <= 0 {
            close()
        }
    }

    private func finishClosing(panel: NSPanel, notifying: Bool) {
        panel.orderOut(nil)
        self.panel = nil
        model = nil
        finalFrame = nil
        isClosing = false
        if notifying {
            let callback = onClose
            onClose = nil
            callback?()
        } else {
            onClose = nil
        }
    }

    private func frame(
        size: NSSize,
        position: ReminderPosition,
        visibleFrame: NSRect,
        menuBarButton: NSStatusBarButton?
    ) -> NSRect {
        let margin: CGFloat = 12
        let origin: NSPoint
        switch position {
        case .center:
            origin = NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2
            )
        case .topCenter:
            origin = NSPoint(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.maxY - size.height - margin
            )
        case .topRight:
            origin = NSPoint(
                x: visibleFrame.maxX - size.width - margin,
                y: visibleFrame.maxY - size.height - margin
            )
        case .belowMenuBar:
            if let button = menuBarButton, let window = button.window {
                let buttonFrame = window.convertToScreen(button.frame)
                origin = NSPoint(
                    x: min(
                        max(buttonFrame.midX - size.width / 2, visibleFrame.minX + margin),
                        visibleFrame.maxX - size.width - margin
                    ),
                    y: visibleFrame.maxY - size.height - margin
                )
            } else {
                origin = NSPoint(
                    x: visibleFrame.midX - size.width / 2,
                    y: visibleFrame.maxY - size.height - margin
                )
            }
        }
        return NSRect(origin: origin, size: size)
    }
}

private final class PassiveReminderPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
