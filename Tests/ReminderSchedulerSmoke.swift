import AppKit
import Foundation
import SwiftUI

@main
struct ReminderSchedulerSmoke {
    @MainActor
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let tasks = (0..<5).map { index in
            TaskItem(
                id: UUID(),
                text: "待办 \(index)",
                status: .pending,
                order: index,
                createdAt: now,
                updatedAt: now,
                completedAt: nil
            )
        }
        var reminderTask = tasks[3]
        reminderTask.reminder = .once(at: now.addingTimeInterval(60))
        let lightTasks = ReminderScheduler.lightReminderTasks(
            in: Array(tasks.prefix(3)) + [reminderTask]
        )
        precondition(lightTasks.map(\.text) == ["待办 0"])

        var laterTask = tasks[4]
        laterTask.reminder = .daily(minuteOfDay: 10 * 60)
        let filtered = ReminderScheduler.lightReminderTasks(
            in: tasks + [laterTask]
        )
        precondition(filtered.count == 1)
        precondition(ReminderPanelController.tasksForTest([]).count == 1)
        precondition(
            ReminderPanelController.tasksForTest([])[0].text == "这是一次轻提醒测试"
        )
        precondition(ReminderPanelController.resolvedSoundName("不存在的声音") == "Glass")
        precondition(ReminderPanelController.dedicatedSoundRepeatCount == 3)

        let view = NSHostingView(
            rootView: ReminderView(
                title: "待办提醒",
                totalCount: 2,
                taskTexts: ["整理任务"],
                model: ReminderPresentationModel(),
                onOpen: {},
                onClose: {}
            )
        )
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 300)
        view.layoutSubtreeIfNeeded()
        precondition(view.fittingSize.width == 420)

        var playedSounds: [String] = []
        let controller = ReminderPanelController { name in
            playedSounds.append(name)
        }
        controller.show(
            tasks: tasks.prefix(1).map { $0 },
            position: .topCenter,
            menuBarButton: nil,
            playsSound: false,
            onOpen: {},
            onClose: {}
        )
        precondition(playedSounds.isEmpty)
        controller.close(animated: false, notifying: false)

        print("Reminder scheduler smoke passed.")
    }
}
