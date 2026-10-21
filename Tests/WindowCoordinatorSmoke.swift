import AppKit
import Foundation
import SwiftUI

@main
struct WindowCoordinatorSmoke {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListWindowTests-\(UUID().uuidString)")
        let store = TaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        let coordinator = WindowCoordinator(taskStore: store)

        precondition(WindowCoordinator.mainPanelWidth == 380)
        precondition(WindowCoordinator.mainPanelMaximumHeight == 560)
        precondition(WindowCoordinator.homeWindowDefaultSize.width == 400)
        precondition(WindowCoordinator.homeWindowDefaultSize.height == 660)
        precondition(WindowCoordinator.homeWindowMinimumSize.width == 380)
        precondition(WindowCoordinator.homeWindowAutosaveName == "MonoList.HomeWindow.CompactV4")

        let panelWindow = NSPanel()
        let homeWindow = NSWindow()
        precondition(
            !WindowCoordinator.shouldCloseMainPanel(
                clickedWindow: panelWindow,
                mainPanel: panelWindow,
                homeWindow: homeWindow
            )
        )
        precondition(
            WindowCoordinator.shouldCloseMainPanel(
                clickedWindow: homeWindow,
                mainPanel: panelWindow,
                homeWindow: homeWindow
            )
        )
        precondition(
            !WindowCoordinator.shouldCloseMainPanel(
                clickedWindow: nil,
                mainPanel: panelWindow,
                homeWindow: homeWindow
            )
        )

        let originalFrame = NSRect(x: 120, y: 300, width: 336, height: 180)
        let expandedFrame = WindowCoordinator.mainPanelFrame(
            keepingTopOf: originalFrame,
            height: 260
        )
        precondition(expandedFrame.minY == 220)
        precondition(expandedFrame.maxY == originalFrame.maxY)
        let halfwayFrame = WindowCoordinator.interpolatedMainPanelFrame(
            from: originalFrame,
            to: expandedFrame,
            progress: 0.5
        )
        precondition(halfwayFrame.height == 220)
        precondition(halfwayFrame.maxY == originalFrame.maxY)

        precondition(
            TaskListView.contentHeight(
                rowCount: 13,
                additionalLineCount: 2,
                dateHeaderCount: 1
            ) > WindowCoordinator.mainPanelMaximumHeight
        )
        precondition(
            SettingsView.nextReminderStatusText(
                enabled: true,
                lightReminderTaskCount: 0,
                nextReminderDate: nil,
                relativeTo: Date()
            ) == "暂无待办"
        )
        precondition(
            SettingsView.nextReminderStatusText(
                enabled: false,
                lightReminderTaskCount: 2,
                nextReminderDate: Date(),
                relativeTo: Date()
            ) == "未启用"
        )

        var submitCount = 0
        let editor = TaskSubmitTextView()
        editor.onSubmit = { submitCount += 1 }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        precondition(submitCount == 1)

        let taskListSource = try String(
            contentsOfFile: "MonoList/Tasks/TaskListView.swift",
            encoding: .utf8
        )
        let homeSource = try String(
            contentsOfFile: "MonoList/Tasks/HomeView.swift",
            encoding: .utf8
        )
        precondition(!homeSource.contains("Text(\"设置\")"))
        precondition(homeSource.contains("onBack: { presentation.section = .tasks }"))
        let windowSource = try String(
            contentsOfFile: "MonoList/App/WindowCoordinator.swift",
            encoding: .utf8
        )
        precondition(!taskListSource.contains("focusStore"))
        precondition(!taskListSource.contains("今日专注"))
        precondition(homeSource.contains("presentation.section = .settings"))
        precondition(homeSource.contains("SettingsView("))
        precondition(windowSource.contains("homeWindow: self.homeWindow"))
        precondition(windowSource.contains("private final class HomeWindow"))
        precondition(windowSource.contains("let editor = firstResponder as? NSTextView"))
        precondition(!windowSource.contains("private var settingsWindow"))

        coordinator.showMainPanel(at: NSPoint(x: 700, y: 800))
        try await Task.sleep(nanoseconds: 50_000_000)
        coordinator.closeMainPanel(animated: false)
        let previousCollapsed = TaskExpansionState.shared.collapsedTaskIDs
        defer { TaskExpansionState.shared.collapsedTaskIDs = previousCollapsed }
        let parent = try store.add(text: "布局测试父任务")
        for index in 0..<6 {
            _ = try store.add(text: "子任务 \(index)", parentID: parent.id)
        }
        TaskExpansionState.shared.collapsedTaskIDs = [parent.id]
        coordinator.showMainPanel(at: NSPoint(x: 700, y: 800))
        try await Task.sleep(nanoseconds: 500_000_000)
        let visiblePanel = NSApp.windows.first {
            $0 is NSPanel && $0.isVisible && $0.frame.width == WindowCoordinator.mainPanelWidth
        }!
        precondition(TaskExpansionState().collapsedTaskIDs.contains(parent.id))
        let collapsedHeight = visiblePanel.frame.height
        precondition(collapsedHeight < 300, "Collapsed children must not inflate panel height")
        TaskExpansionState.shared.collapsedTaskIDs = []
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(visiblePanel.frame.height > collapsedHeight + 50, "Expanded \(visiblePanel.frame.height), collapsed \(collapsedHeight)")
        TaskExpansionState.shared.collapsedTaskIDs = [parent.id]
        try await Task.sleep(nanoseconds: 500_000_000)
        precondition(abs(visiblePanel.frame.height - collapsedHeight) < 2)
        coordinator.closeMainPanel(animated: false)
        coordinator.showMainPanel(at: NSPoint(x: 700, y: 800))
        try await Task.sleep(nanoseconds: 500_000_000)
        let reopenedPanel = NSApp.windows.first {
            $0 is NSPanel && $0.isVisible && $0.frame.width == WindowCoordinator.mainPanelWidth
        }!
        precondition(abs(reopenedPanel.frame.height - collapsedHeight) < 2)
        coordinator.closeMainPanel(animated: false)
        print("Window coordinator smoke passed.")
    }
}
