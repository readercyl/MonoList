import AppKit
import Foundation
import SwiftUI

@main
struct WindowCoordinatorSmoke {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListWindowTests-\(UUID().uuidString)")
        let store = TaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        let focusStore = FocusStore(
            fileURL: directory.appendingPathComponent("focus.json")
        )
        let coordinator = WindowCoordinator(taskStore: store, focusStore: focusStore)

        precondition(WindowCoordinator.mainPanelWidth == 336)
        precondition(WindowCoordinator.mainPanelMaximumHeight == 447)
        precondition(WindowCoordinator.settingsWindowWidth == 430)
        let visibleFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fallbackAnchor = WindowCoordinator.fallbackMainPanelAnchor(
            in: visibleFrame,
            menuBarBottomY: 866
        )
        precondition(fallbackAnchor.y == 866)
        precondition(
            fallbackAnchor.x == visibleFrame.maxX -
                WindowCoordinator.mainPanelWidth / 2 - 8
        )
        let statusItemFrame = NSRect(x: 1180, y: 876, width: 72, height: 24)
        let statusItemAnchor = WindowCoordinator.mainPanelAnchor(
            below: statusItemFrame,
            in: visibleFrame
        )
        precondition(statusItemAnchor == NSPoint(x: 1216, y: 900))
        precondition(
            WindowCoordinator.isStatusItemClick(
                NSPoint(x: 1216, y: 888),
                frame: statusItemFrame
            )
        )
        precondition(
            !WindowCoordinator.isStatusItemClick(
                NSPoint(x: 1100, y: 888),
                frame: statusItemFrame
            )
        )
        let originalFrame = NSRect(x: 120, y: 300, width: 336, height: 180)
        let expandedFrame = WindowCoordinator.mainPanelFrame(
            keepingTopOf: originalFrame,
            height: 260
        )
        precondition(expandedFrame.minY == 220)
        precondition(expandedFrame.maxY == originalFrame.maxY)
        precondition(expandedFrame.width == originalFrame.width)
        let collapsedFrame = WindowCoordinator.mainPanelFrame(
            keepingTopOf: expandedFrame,
            height: 120
        )
        precondition(collapsedFrame.maxY == originalFrame.maxY)
        let halfwayFrame = WindowCoordinator.interpolatedMainPanelFrame(
            from: originalFrame,
            to: expandedFrame,
            progress: 0.5
        )
        precondition(halfwayFrame.height == 220)
        precondition(halfwayFrame.maxY == originalFrame.maxY)
        let mismatchedEndFrame = NSRect(x: 120, y: 100, width: 336, height: 260)
        let anchoredHalfwayFrame = WindowCoordinator.interpolatedMainPanelFrame(
            from: originalFrame,
            to: mismatchedEndFrame,
            progress: 0.5
        )
        precondition(anchoredHalfwayFrame.maxY == originalFrame.maxY)
        var changingFrame = originalFrame
        for height: CGFloat in [216, 263, 341, 447, 341, 216] {
            changingFrame = WindowCoordinator.mainPanelFrame(
                keepingTopOf: changingFrame,
                height: height
            )
            precondition(changingFrame.maxY == originalFrame.maxY)
        }
        precondition(WindowCoordinator.requiresScrolling(contentHeight: 479))
        precondition(WindowCoordinator.requiresScrolling(contentHeight: 481))
        precondition(
            WindowCoordinator.preferredMainPanelHeight(
                pendingCount: 0,
                todayCompletedCount: 0,
                olderVisibleCount: 0
            ) < 148
        )
        precondition(
            WindowCoordinator.preferredMainPanelHeight(
                pendingCount: 20,
                todayCompletedCount: 10,
                olderVisibleCount: 10
            ) == WindowCoordinator.mainPanelMaximumHeight
        )
        precondition(
            WindowCoordinator.preferredMainPanelHeight(
                pendingCount: 2,
                todayCompletedCount: 7,
                olderVisibleCount: 0
            ) == 430
        )
        let focusNow = Date()
        let focusTasks = [
            TaskItem(
                id: UUID(), text: "完成票根小程序开发", status: .pending,
                order: 0, createdAt: focusNow, updatedAt: focusNow, completedAt: nil
            ),
            TaskItem(
                id: UUID(), text: "整理本周发布说明", status: .pending,
                order: 1, createdAt: focusNow, updatedAt: focusNow, completedAt: nil
            ),
            TaskItem(
                id: UUID(), text: "回复设计评审意见", status: .pending,
                order: 2, createdAt: focusNow, updatedAt: focusNow, completedAt: nil
            ),
        ]
        let oneFocusHeight = TaskListView.focusContentHeight(
            for: Array(focusTasks.prefix(1))
        )
        let threeFocusHeight = TaskListView.focusContentHeight(for: focusTasks)
        precondition(oneFocusHeight == 216)
        precondition(threeFocusHeight > oneFocusHeight)
        precondition(threeFocusHeight < 348)
        precondition(
            TaskListView.additionalLines(
                for: "shotlens升级。线上部署，把key放入安全环境。控制台 UI比例调整。"
            ) == 1
        )
        precondition(
            TaskListView.contentHeight(
                rowCount: 7,
                additionalLineCount: 7,
                dateHeaderCount: 0
            ) == WindowCoordinator.mainPanelMaximumHeight
        )
        precondition(
            TaskListView.contentHeight(
                rowCount: 8,
                additionalLineCount: 8,
                dateHeaderCount: 0
            ) > WindowCoordinator.mainPanelMaximumHeight
        )
        precondition(
            SettingsView.nextReminderStatusText(
                enabled: true,
                hasActiveFocus: true,
                lightReminderTaskCount: 0,
                nextReminderDate: nil,
                relativeTo: focusNow
            ) == "今日专注已完成"
        )
        precondition(
            SettingsView.nextReminderStatusText(
                enabled: true,
                hasActiveFocus: false,
                lightReminderTaskCount: 0,
                nextReminderDate: nil,
                relativeTo: focusNow
            ) == "暂无待办"
        )
        precondition(
            SettingsView.nextReminderStatusText(
                enabled: false,
                hasActiveFocus: true,
                lightReminderTaskCount: 1,
                nextReminderDate: focusNow,
                relativeTo: focusNow
            ) == "未启用"
        )
        let panelWindow = NSPanel()
        let settingsWindow = NSWindow()
        precondition(
            !WindowCoordinator.shouldCloseMainPanel(
                clickedWindow: panelWindow,
                mainPanel: panelWindow,
                settingsWindow: settingsWindow
            )
        )
        precondition(
            WindowCoordinator.shouldCloseMainPanel(
                clickedWindow: settingsWindow,
                mainPanel: panelWindow,
                settingsWindow: settingsWindow
            )
        )
        var directSubmitCount = 0
        let directEditor = TaskSubmitTextView()
        directEditor.onSubmit = { directSubmitCount += 1 }
        directEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(directSubmitCount == 1)
        directEditor.string = "可以复制的待办"
        let selectAllEvent = commandKeyEvent(character: "a", keyCode: 0)
        precondition(directEditor.performKeyEquivalent(with: selectAllEvent))
        precondition(directEditor.selectedRange() == NSRange(location: 0, length: 7))
        NSPasteboard.general.clearContents()
        let copyEvent = commandKeyEvent(character: "c", keyCode: 8)
        precondition(directEditor.performKeyEquivalent(with: copyEvent))
        precondition(NSPasteboard.general.string(forType: .string) == "可以复制的待办")
        let cutEvent = commandKeyEvent(character: "x", keyCode: 7)
        precondition(directEditor.performKeyEquivalent(with: cutEvent))
        precondition(directEditor.string.isEmpty)
        let pasteEvent = commandKeyEvent(character: "v", keyCode: 9)
        precondition(directEditor.performKeyEquivalent(with: pasteEvent))
        precondition(directEditor.string == "可以复制的待办")
        let configuredEditorHost = NSHostingView(
            rootView: TaskEditorSizingProbe(text: "")
        )
        configuredEditorHost.frame = NSRect(x: 0, y: 0, width: 310, height: 90)
        let configuredEditorWindow = NSWindow(
            contentRect: configuredEditorHost.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        configuredEditorWindow.contentView = configuredEditorHost
        configuredEditorHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        configuredEditorHost.layoutSubtreeIfNeeded()
        guard let configuredEditor = findTaskTextView(in: configuredEditorHost) else {
            throw CocoaError(.coderInvalidValue)
        }
        precondition(!configuredEditor.isAutomaticTextReplacementEnabled)
        precondition(!configuredEditor.isAutomaticQuoteSubstitutionEnabled)
        precondition(!configuredEditor.isAutomaticDashSubstitutionEnabled)
        precondition(!configuredEditor.isAutomaticSpellingCorrectionEnabled)
        precondition(configuredEditor.enabledTextCheckingTypes == 0)
        let emptyDraftHeight = try measuredTaskEditorHeight(
            text: "",
            width: 310,
            offeredHeight: 90
        )
        precondition(emptyDraftHeight <= 18)
        let wrappedDraftHeight = try measuredTaskEditorHeight(
            text: "这是一条足够长的待办内容，用来验证输入框只有在文本真的需要换行时才自动变成两行显示。",
            width: 310,
            offeredHeight: 90
        )
        precondition(wrappedDraftHeight > emptyDraftHeight)
        let threeLineDraftHeight = try measuredTaskEditorHeight(
            text: "第一行\n第二行\n第三行",
            width: 310,
            offeredHeight: 200
        )
        let fourLineDraftHeight = try measuredTaskEditorHeight(
            text: "第一行\n第二行\n第三行\n第四行",
            width: 310,
            offeredHeight: 200
        )
        precondition(fourLineDraftHeight > threeLineDraftHeight)
        let taskListSource = try String(
            contentsOfFile: "MonoList/Tasks/TaskListView.swift",
            encoding: .utf8
        )
        precondition(
            taskListSource.contains("onSelect: { selectTask(item.id) }")
        )
        precondition(
            taskListSource.contains("private func selectTask(_ id: UUID)")
        )
        precondition(
            taskListSource.contains("private func focusDraft(after id: UUID?, in group: TaskGroup")
        )
        precondition(taskListSource.contains("DraftRowHeightPreferenceKey"))
        precondition(
            taskListSource.contains("TaskDragPreview(text:")
        )
        precondition(taskListSource.contains("withAnimation("))
        precondition(taskListSource.contains(".easeOut(duration: 0.16)"))
        precondition(
            taskListSource.contains(
                "let startsWithOtherTasks = !focusStore.isActive()"
            ) && taskListSource.contains(
                "_showsOtherTasks = State(initialValue: startsWithOtherTasks)"
            ) && taskListSource.contains(
                "_rendersOtherTasks = State(initialValue: startsWithOtherTasks)"
            )
        )
        precondition(
            taskListSource.contains(".animation(nil, value: preferredHeight)")
        )
        precondition(
            !taskListSource.contains(
                ".animation(layoutAnimation, value: showsOtherTasks)"
            ),
            "其他待办不能再次驱动整个 SwiftUI 布局动画"
        )
        precondition(
            taskListSource.contains("idealHeight: preferredHeight") &&
                taskListSource.contains("rendersOtherTasks"),
            "窗口内容必须跟随当前视口，并在收起结束后再移除其他待办"
        )
        precondition(
            !taskListSource.contains(
                "store.completedTasks(on: currentDate).filter"
            ),
            "今日完成的专注任务不能从已完成列表中过滤"
        )
        precondition(
            !taskListSource.contains(
                "store.completedTasks(before: currentDate).filter"
            ),
            "历史专注任务不能从已完成列表中过滤"
        )
        precondition(taskListSource.contains("focusPickerAnchor"))
        precondition(taskListSource.contains("arrowEdge: .trailing"))
        precondition(taskListSource.contains("matchedGeometryEffect"))
        precondition(taskListSource.contains("scrollDisabled(false)"))
        precondition(taskListSource.contains("private var scrollableTaskContent"))
        let windowCoordinatorSource = try String(
            contentsOfFile: "MonoList/App/WindowCoordinator.swift",
            encoding: .utf8
        )
        precondition(windowCoordinatorSource.contains("weak var panelReference"))
        precondition(!windowCoordinatorSource.contains("startFrame.origin.y += 4"))
        precondition(!windowCoordinatorSource.contains("targetFrame.origin.y += 4"))
        precondition(
            !windowCoordinatorSource.contains(
                "panel.animator().setFrame(finalFrame, display: true)"
            )
        )
        let taskRowSource = try String(
            contentsOfFile: "MonoList/Tasks/TaskRowView.swift",
            encoding: .utf8
        )
        precondition(
            taskRowSource.contains(".fixedSize(horizontal: false, vertical: true)"),
            "带提醒的多行任务正文不能被面板高度压缩"
        )
        precondition(taskRowSource.contains("struct TaskCompletionButton"))
        precondition(taskRowSource.contains("let delay = reduceMotion ? 0 : 0.24"))
        precondition(taskRowSource.contains("guard !isEditingMode else { return }"))
        let headerIconStart = taskListSource.range(
            of: "private struct HeaderIconLabel"
        )
        let headerIconEnd = taskListSource.range(
            of: "private struct TaskDragPreview"
        )
        precondition(headerIconStart != nil && headerIconEnd != nil)
        let headerIconSource = taskListSource[
            headerIconStart!.lowerBound..<headerIconEnd!.lowerBound
        ]
        precondition(!headerIconSource.contains(".background"))
        precondition(!headerIconSource.contains(".overlay"))
        precondition(!headerIconSource.contains("RoundedRectangle"))
        let settingsSource = try String(
            contentsOfFile: "MonoList/Settings/SettingsView.swift",
            encoding: .utf8
        )
        precondition(settingsSource.contains("SettingsPopupButton("))
        precondition(settingsSource.contains("SettingValueBackground"))
        precondition(settingsSource.contains("SettingsSwitchStyle"))
        precondition(!settingsSource.contains("NSComboBox"))
        precondition(!settingsSource.contains(".toggleStyle(.switch)"))
        precondition(
            settingsSource.contains("private static let controlWidth: CGFloat = 180")
        )
        precondition(settingsSource.contains("maxVisibleItems: 8"))
        precondition(settingsSource.contains("ScrollView(.vertical"))
        precondition(
            settingsSource.contains("FixedQuietButtonStyle(width: 180)")
        )
        let timeRow = settingsSource.range(of: "settingsRow(\"提醒时段\")")
        let intervalRow = settingsSource.range(of: "settingsRow(\"提醒间隔\")")
        precondition(timeRow != nil && intervalRow != nil)
        precondition(timeRow!.lowerBound < intervalRow!.lowerBound)
        let enterDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListEnterTests-\(UUID().uuidString)")
        let enterStore = TaskStore(
            fileURL: enterDirectory.appendingPathComponent("tasks.json")
        )
        let enterDraft = TaskDraftState()
        enterDraft.present(after: nil)
        enterDraft.text = "加号或双击新增的待办"
        directEditor.onSubmit = {
            try! enterDraft.submitAndContinue(to: enterStore)
        }
        directEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(enterStore.pendingTasks.map(\.text) == ["加号或双击新增的待办"])
        precondition(enterDraft.isPresented)
        precondition(enterDraft.text.isEmpty)
        enterDraft.text = "下一行待办"
        directEditor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(
            enterStore.pendingTasks.map(\.text) ==
                ["加号或双击新增的待办", "下一行待办"]
        )
        precondition(enterDraft.isPresented)

        let draft = TaskDraftState()
        draft.syncVisibility(hasPendingTasks: false)
        precondition(draft.isPresented)
        draft.text = "还没有按回车"
        precondition(draft.text == "还没有按回车")
        precondition(store.pendingTasks.isEmpty)
        try draft.submit(to: store)
        precondition(store.pendingTasks.map(\.text) == ["还没有按回车"])
        precondition(draft.text.isEmpty)
        precondition(!draft.isPresented)
        draft.present(after: store.pendingTasks.last?.id)
        precondition(draft.isPresented)
        draft.dismissIfEmpty()
        precondition(!draft.isPresented)
        draft.present(after: nil)
        draft.text = "保留的草稿"
        try draft.commitOrDismiss(to: store)
        precondition(store.pendingTasks.map(\.text) == ["还没有按回车", "保留的草稿"])
        precondition(!draft.isPresented)
        draft.present(after: store.pendingTasks.last?.id)
        try draft.commitOrDismiss(to: store)
        precondition(store.pendingTasks.count == 2)
        precondition(!draft.isPresented)
        draft.present(after: store.pendingTasks.last?.id)
        draft.text = "连续输入第一条"
        let continuedItem = try draft.submitAndContinue(to: store)
        precondition(continuedItem?.text == "连续输入第一条")
        precondition(draft.isPresented)
        precondition(draft.text.isEmpty)
        precondition(draft.afterID == continuedItem?.id)
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let testAnchor = NSPoint(x: 500, y: 500)
        coordinator.showMainPanel(at: testAnchor)
        precondition(coordinator.isMainPanelVisible)
        guard let displayedMainWindow = NSApp.windows.first(where: {
            !existingWindows.contains(ObjectIdentifier($0)) && $0.isVisible
        }) else {
            throw CocoaError(.coderInvalidValue)
        }
        guard let displayedHostingView = displayedMainWindow.contentView as? NSHostingView<TaskListView> else {
            throw CocoaError(.coderInvalidValue)
        }
        precondition(
            displayedHostingView.sizingOptions.isEmpty,
            "主窗口显示后必须由 AppKit 外框单独控制高度"
        )
        precondition(abs(displayedMainWindow.frame.maxY - testAnchor.y) < 0.5)
        for index in 0..<5 {
            try store.add(text: "动态高度测试 \(index)")
        }
        let resizeDeadline = Date().addingTimeInterval(0.35)
        while Date() < resizeDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            precondition(abs(displayedMainWindow.frame.maxY - testAnchor.y) < 0.5)
        }
        coordinator.closeMainPanel(animated: false)
        precondition(!coordinator.isMainPanelVisible)

        let focusDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListFocusWindowTests-\(UUID().uuidString)")
        let focusTaskStore = TaskStore(
            fileURL: focusDirectory.appendingPathComponent("tasks.json")
        )
        let focusWindowStore = FocusStore(
            fileURL: focusDirectory.appendingPathComponent("focus.json")
        )
        var focusWindowTasks: [TaskItem] = []
        for index in 0..<7 {
            focusWindowTasks.append(
                try focusTaskStore.add(text: "专注窗口动态测试 \(index)")
            )
        }
        try focusWindowStore.setSelection(
            [focusWindowTasks[0].id],
            existingTaskIDs: Set(focusWindowTasks.map(\.id)),
            completedTaskIDs: [],
            at: Date()
        )
        let focusCoordinator = WindowCoordinator(
            taskStore: focusTaskStore,
            focusStore: focusWindowStore
        )
        let windowsBeforeFocusPanel = Set(NSApp.windows.map(ObjectIdentifier.init))
        let focusAnchor = NSPoint(x: 700, y: 800)
        focusCoordinator.showMainPanel(at: focusAnchor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let focusMainWindow = NSApp.windows.first(where: {
            !windowsBeforeFocusPanel.contains(ObjectIdentifier($0)) && $0.isVisible
        }) else {
            throw CocoaError(.coderInvalidValue)
        }
        let collapsedHeight = focusMainWindow.frame.height
        precondition(abs(focusMainWindow.frame.maxY - focusAnchor.y) < 0.5)
        click(window: focusMainWindow, at: NSPoint(x: 150, y: 20))
        var previousHeight = focusMainWindow.frame.height
        let disclosureDeadline = Date().addingTimeInterval(0.4)
        while Date() < disclosureDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let frame = focusMainWindow.frame
            precondition(abs(frame.maxY - focusAnchor.y) < 0.5)
            precondition(frame.height + 0.5 >= previousHeight)
            previousHeight = frame.height
        }
        precondition(focusMainWindow.frame.height > collapsedHeight + 20)
        let expandedScrollViews = scrollViews(in: focusMainWindow.contentView)
        precondition(expandedScrollViews.contains { scrollView in
            guard let documentView = scrollView.documentView else { return false }
            return documentView.frame.height > scrollView.contentView.bounds.height + 1
        })
        click(
            window: focusMainWindow,
            at: NSPoint(
                x: 150,
                y: focusMainWindow.frame.height - collapsedHeight + 20
            )
        )
        previousHeight = focusMainWindow.frame.height
        let collapseDeadline = Date().addingTimeInterval(0.4)
        while Date() < collapseDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            let frame = focusMainWindow.frame
            precondition(abs(frame.maxY - focusAnchor.y) < 0.5)
            precondition(frame.height <= previousHeight + 0.5)
            previousHeight = frame.height
        }
        precondition(focusMainWindow.frame.height <= collapsedHeight + 1)
        focusCoordinator.closeMainPanel(animated: false)

        let pickerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListFocusPickerTests-\(UUID().uuidString)")
        let pickerTaskStore = TaskStore(
            fileURL: pickerDirectory.appendingPathComponent("tasks.json")
        )
        let pickerFocusStore = FocusStore(
            fileURL: pickerDirectory.appendingPathComponent("focus.json")
        )
        for index in 0..<7 {
            try pickerTaskStore.add(text: "专注选择浮窗测试 \(index)")
        }
        let pickerCoordinator = WindowCoordinator(
            taskStore: pickerTaskStore,
            focusStore: pickerFocusStore
        )
        let windowsBeforePickerPanel = Set(NSApp.windows.map(ObjectIdentifier.init))
        pickerCoordinator.showMainPanel(at: focusAnchor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let pickerMainWindow = NSApp.windows.first(where: {
            !windowsBeforePickerPanel.contains(ObjectIdentifier($0)) && $0.isVisible
        }) else {
            throw CocoaError(.coderInvalidValue)
        }
        let expandedHeight = pickerMainWindow.frame.height
        let visibleWindowsBeforePopover = Set(
            NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init)
        )
        click(
            window: pickerMainWindow,
            at: NSPoint(x: 150, y: expandedHeight - 84)
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let focusPickerWindow = NSApp.windows.first(where: {
            !visibleWindowsBeforePopover.contains(ObjectIdentifier($0)) && $0.isVisible
        }) else {
            throw CocoaError(.coderInvalidValue)
        }
        precondition(
            focusPickerWindow.frame.minX >= pickerMainWindow.frame.maxX - 4,
            "主窗口 \(pickerMainWindow.frame)，浮窗 \(focusPickerWindow.frame)"
        )
        click(
            window: focusPickerWindow,
            at: NSPoint(x: 120, y: focusPickerWindow.frame.height - 62)
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        precondition(pickerFocusStore.taskIDs().count == 1)
        precondition(abs(pickerMainWindow.frame.maxY - focusAnchor.y) < 0.5)
        precondition(pickerMainWindow.frame.height >= expandedHeight - 1)
        pickerCoordinator.closeMainPanel(animated: false)

        let completionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListCompletionMotionTests-\(UUID().uuidString)")
        let completionStore = TaskStore(
            fileURL: completionDirectory.appendingPathComponent("tasks.json")
        )
        let completionFocusStore = FocusStore(
            fileURL: completionDirectory.appendingPathComponent("focus.json")
        )
        for index in 0..<3 {
            try completionStore.add(text: "完成动效测试 \(index)")
        }
        let completionCoordinator = WindowCoordinator(
            taskStore: completionStore,
            focusStore: completionFocusStore
        )
        let windowsBeforeCompletionPanel = Set(NSApp.windows.map(ObjectIdentifier.init))
        completionCoordinator.showMainPanel(at: focusAnchor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard let completionMainWindow = NSApp.windows.first(where: {
            !windowsBeforeCompletionPanel.contains(ObjectIdentifier($0)) && $0.isVisible
        }) else {
            throw CocoaError(.coderInvalidValue)
        }
        click(
            window: completionMainWindow,
            at: NSPoint(x: 29, y: completionMainWindow.frame.height - 170)
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(completionStore.pendingTasks.count == 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(completionStore.pendingTasks.count == 2)
        precondition(completionStore.historyTasks.count == 1)
        completionCoordinator.closeMainPanel(animated: false)

        print("Window coordinator smoke passed.")
    }

    @MainActor
    private static func measuredTaskEditorHeight(
        text: String,
        width: CGFloat,
        offeredHeight: CGFloat
    ) throws -> CGFloat {
        let view = NSHostingView(
            rootView: TaskEditorSizingProbe(text: text)
                .frame(width: width, height: offeredHeight)
        )
        view.frame = NSRect(x: 0, y: 0, width: width, height: offeredHeight)
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
        guard let textView = findTaskTextView(in: view) else {
            throw CocoaError(.coderInvalidValue)
        }
        return textView.frame.height
    }

    private static func findTaskTextView(in view: NSView) -> TaskSubmitTextView? {
        if let textView = view as? TaskSubmitTextView {
            return textView
        }
        for subview in view.subviews {
            if let textView = findTaskTextView(in: subview) {
                return textView
            }
        }
        return nil
    }

    private static func commandKeyEvent(character: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private static func click(window: NSWindow, at point: NSPoint) {
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: eventType,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: eventType == .leftMouseDown ? 1 : 0
            ) else {
                preconditionFailure("无法创建窗口点击事件")
            }
            window.sendEvent(event)
        }
    }

    private static func scrollViews(in view: NSView?) -> [NSScrollView] {
        guard let view else { return [] }
        return (view as? NSScrollView).map { [$0] } ??
            view.subviews.flatMap { scrollViews(in: $0) }
    }
}

private struct TaskEditorSizingProbe: View {
    @State private var text: String
    @State private var isFocused = false

    init(text: String) {
        _text = State(initialValue: text)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "circle")
                .font(.system(size: 18))
                .frame(width: 28, height: 28)
            TaskTextEditor(
                text: $text,
                isFocused: $isFocused,
                onSubmit: {}
            )
            .padding(.vertical, 5)
            Color.clear.frame(width: 28, height: 28)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}
