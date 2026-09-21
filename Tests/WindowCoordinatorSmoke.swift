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
        let coordinator = WindowCoordinator(taskStore: store)

        precondition(WindowCoordinator.mainPanelWidth == 336)
        precondition(WindowCoordinator.mainPanelMaximumHeight == 560)
        precondition(WindowCoordinator.homeWindowDefaultSize.width == 400)
        precondition(WindowCoordinator.homeWindowDefaultSize.height == 720)
        precondition(WindowCoordinator.homeWindowMinimumSize.width == 380)
        precondition(WindowCoordinator.homeWindowAutosaveName == "MonoList.HomeWindow.CompactV3")

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
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        coordinator.closeMainPanel(animated: false)
        print("Window coordinator smoke passed.")
    }
}
