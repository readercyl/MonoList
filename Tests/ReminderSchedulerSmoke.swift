import AppKit
import Foundation
import SwiftUI

@main
struct ReminderSchedulerSmoke {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        var now: TimeInterval = 100
        let calendar = fixedCalendar()
        var wallClock = fixedDate(hour: 10, minute: 0, calendar: calendar)
        var triggerCount = 0
        var dedicatedReminderIDs: [UUID] = []
        let scheduler = ReminderScheduler(
            now: { now },
            wallClock: { wallClock },
            calendar: calendar,
            onDue: { triggerCount += 1 },
            onDedicatedReminderDue: { dedicatedReminderIDs.append($0) }
        )
        let dedicatedID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let dedicatedTask = TaskItem(
            id: dedicatedID,
            text: "晚上六点提醒我",
            status: .pending,
            order: 0,
            createdAt: fixedDate(hour: 9, minute: 0, calendar: calendar),
            updatedAt: fixedDate(hour: 9, minute: 0, calendar: calendar),
            completedAt: nil,
            reminder: .once(at: fixedDate(hour: 18, minute: 0, calendar: calendar))
        )

        scheduler.configure(
            enabled: true,
            intervalMinutes: 60,
            startMinuteOfDay: 9 * 60,
            endMinuteOfDay: 22 * 60,
            pendingTasks: [dedicatedTask]
        )
        precondition(scheduler.deadline == 3_700)
        precondition(
            scheduler.nextReminderDate ==
                fixedDate(hour: 11, minute: 0, calendar: calendar)
        )

        scheduler.pendingCountChanged(from: 1, to: 2)
        precondition(scheduler.deadline == 3_700)

        now = 3_700
        scheduler.evaluate(interfaceBusy: true)
        precondition(triggerCount == 0)
        precondition(scheduler.deadline == 7_300)

        now = 7_300
        scheduler.evaluate(interfaceBusy: false)
        precondition(triggerCount == 1)
        precondition(scheduler.deadline == nil)

        scheduler.reminderClosed(pendingCount: 2)
        precondition(scheduler.deadline == 10_900)

        scheduler.pendingCountChanged(from: 2, to: 0)
        precondition(scheduler.deadline == nil)

        now = 8_000
        scheduler.pendingCountChanged(from: 0, to: 1)
        precondition(scheduler.deadline == 11_600)
        scheduler.wake(pendingCount: 1)
        precondition(scheduler.deadline == 11_600)

        precondition(
            ReminderScheduler.nextReminderDate(
                after: fixedDate(hour: 8, minute: 0, calendar: calendar),
                intervalMinutes: 30,
                startMinuteOfDay: 9 * 60,
                endMinuteOfDay: 22 * 60,
                calendar: calendar
            ) == fixedDate(hour: 9, minute: 0, calendar: calendar)
        )
        precondition(
            ReminderScheduler.nextReminderDate(
                after: fixedDate(hour: 8, minute: 50, calendar: calendar),
                intervalMinutes: 30,
                startMinuteOfDay: 9 * 60,
                endMinuteOfDay: 22 * 60,
                calendar: calendar
            ) == fixedDate(hour: 9, minute: 20, calendar: calendar)
        )
        precondition(
            ReminderScheduler.nextReminderDate(
                after: fixedDate(hour: 21, minute: 45, calendar: calendar),
                intervalMinutes: 30,
                startMinuteOfDay: 9 * 60,
                endMinuteOfDay: 22 * 60,
                calendar: calendar
            ) == fixedDate(dayOffset: 1, hour: 9, minute: 0, calendar: calendar)
        )
        wallClock = fixedDate(hour: 21, minute: 45, calendar: calendar)
        now = 20_000
        scheduler.configure(
            enabled: true,
            intervalMinutes: 30,
            startMinuteOfDay: 9 * 60,
            endMinuteOfDay: 22 * 60,
            pendingTasks: [dedicatedTask]
        )
        precondition(
            scheduler.nextReminderDate ==
                fixedDate(dayOffset: 1, hour: 9, minute: 0, calendar: calendar)
        )

        wallClock = fixedDate(hour: 17, minute: 59, calendar: calendar)
        now = 30_000
        scheduler.configure(
            enabled: true,
            intervalMinutes: 30,
            startMinuteOfDay: 9 * 60,
            endMinuteOfDay: 22 * 60,
            pendingTasks: [dedicatedTask]
        )
        let globalDeadlineBeforeDedicatedReminder = scheduler.deadline
        wallClock = fixedDate(hour: 18, minute: 0, calendar: calendar)
        now += 60
        scheduler.evaluate(interfaceBusy: true)
        precondition(
            dedicatedReminderIDs.isEmpty,
            "MonoList 界面繁忙时，单条定时提醒应等待而不是覆盖当前界面"
        )
        scheduler.evaluate(interfaceBusy: false)
        precondition(dedicatedReminderIDs == [dedicatedID])
        precondition(
            scheduler.deadline != globalDeadlineBeforeDedicatedReminder,
            "单条提醒触发后应重置全局轻提醒"
        )

        let deadlineBeforeInteraction = scheduler.deadline
        now += 100
        scheduler.meaningfulInteraction(pendingCount: 1)
        precondition(
            scheduler.deadline != deadlineBeforeInteraction,
            "查看或操作专注任务后应重新计算轻提醒"
        )

        let testTasks = ReminderPanelController.tasksForTest([])
        precondition(testTasks.count == 1)
        precondition(testTasks[0].text == "这是一次轻提醒测试")
        let focusTestTasks = ReminderPanelController.tasksForFocusTest([])
        precondition(focusTestTasks.count == 1)
        precondition(focusTestTasks[0].text == "这是一次专注提醒测试")
        precondition(ReminderPanelController.resolvedSoundName("不存在的声音") == "Glass")
        precondition(ReminderPanelController.displayDurationSeconds == 6)

        let queuedIDs = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000211")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000212")!,
        ]
        let queuedTasks = queuedIDs.enumerated().map { index, id in
            TaskItem(
                id: id,
                text: "同时到期提醒 \(index + 1)",
                status: .pending,
                order: index,
                createdAt: fixedDate(hour: 9, minute: 0, calendar: calendar),
                updatedAt: fixedDate(hour: 9, minute: 0, calendar: calendar),
                completedAt: nil,
                reminder: .once(at: fixedDate(hour: 18, minute: 0, calendar: calendar))
            )
        }
        var queuedDispatches: [UUID] = []
        let queuedScheduler = ReminderScheduler(
            now: { 40_000 },
            wallClock: { fixedDate(hour: 18, minute: 0, calendar: calendar) },
            calendar: calendar,
            onDue: {},
            onDedicatedReminderDue: { queuedDispatches.append($0) }
        )
        queuedScheduler.configure(
            enabled: false,
            intervalMinutes: 60,
            pendingTasks: queuedTasks
        )
        queuedScheduler.evaluate(interfaceBusy: false)
        precondition(
            queuedDispatches == [queuedIDs[0]],
            "关闭轻提醒后，单条定时提醒仍应独立触发"
        )
        queuedScheduler.evaluate(interfaceBusy: true)
        precondition(
            queuedDispatches == [queuedIDs[0]],
            "上一条提醒显示期间不能被下一条覆盖"
        )
        queuedScheduler.evaluate(interfaceBusy: false)
        precondition(
            queuedDispatches == queuedIDs,
            "多条同时到期提醒应按任务顺序逐条展示"
        )
        let longTermTask = TaskItem(
            id: UUID(),
            text: "长期任务不进入轻提醒",
            status: .pending,
            order: 2,
            createdAt: wallClock,
            updatedAt: wallClock,
            completedAt: nil,
            group: .longTerm
        )
        precondition(
            ReminderScheduler.lightReminderTasks(
                in: queuedTasks + [longTermTask],
                focusTaskIDs: nil
            ).map(\.id) == queuedIDs,
            "没有今日专注时，轻提醒只能使用未完成的短期任务"
        )
        precondition(
            ReminderScheduler.lightReminderTasks(
                in: [longTermTask],
                focusTaskIDs: nil
            ).isEmpty,
            "只有长期任务时不应启动轻提醒"
        )
        let overflowTasks = (0..<5).map { index in
            TaskItem(
                id: UUID(),
                text: "短期任务 \(index + 1)",
                status: .pending,
                order: index,
                createdAt: wallClock,
                updatedAt: wallClock,
                completedAt: nil
            )
        }
        precondition(
            ReminderScheduler.lightReminderTasks(
                in: overflowTasks,
                focusTaskIDs: nil
            ).map(\.id) == Array(overflowTasks.prefix(3)).map(\.id),
            "轻提醒弹窗最多只能展示三条短期任务"
        )
        precondition(
            ReminderScheduler.lightReminderTasks(
                in: queuedTasks,
                focusTaskIDs: [queuedIDs[1]]
            ).map(\.id) == [queuedIDs[1]],
            "设置今日专注后，轻提醒只能使用当前专注任务"
        )
        precondition(
            ReminderScheduler.lightReminderTasks(
                in: [longTermTask] + queuedTasks,
                focusTaskIDs: [longTermTask.id, queuedIDs[0]]
            ).isEmpty,
            "当前专注为长期任务时不应跳过它去提醒后续短期任务"
        )
        let completedFocusTask = TaskItem(
            id: UUID(),
            text: "已经完成的专注任务",
            status: .history,
            order: 0,
            createdAt: wallClock,
            updatedAt: wallClock,
            completedAt: wallClock
        )
        precondition(
            ReminderScheduler.lightReminderTasks(
                in: [completedFocusTask] + queuedTasks,
                focusTaskIDs: [completedFocusTask.id]
            ).isEmpty,
            "今日专注全部完成后不应退回普通轻提醒"
        )

        let finalFrame = NSRect(x: 400, y: 500, width: 340, height: 180)
        let startFrame = ReminderPanelController.presentationStartFrame(
            for: finalFrame
        )
        precondition(startFrame.size == finalFrame.size)
        precondition(startFrame.minX == finalFrame.minX)
        precondition(startFrame.minY == finalFrame.minY + 8)
        let reminderModel = ReminderPresentationModel()
        let reminderView = NSHostingView(
            rootView: ReminderView(
                totalCount: 1,
                taskTexts: ["这是一次轻提醒测试"],
                model: reminderModel,
                onOpen: {},
                onClose: {}
            )
        )
        reminderView.frame = NSRect(x: 0, y: 0, width: 340, height: 300)
        reminderView.layoutSubtreeIfNeeded()
        precondition(reminderView.fittingSize.height < 110)

        let focusReminderView = NSHostingView(
            rootView: ReminderView(
                title: "当前专注",
                statusText: "1/3",
                isFocusReminder: true,
                totalCount: 1,
                taskTexts: ["调研沉浸式翻译的技术路线，确认页面结构和交互可以完整保留"],
                model: reminderModel,
                onOpen: {},
                onClose: {}
            )
        )
        focusReminderView.layoutSubtreeIfNeeded()
        precondition(focusReminderView.fittingSize.width == 420)
        precondition(focusReminderView.fittingSize.height >= 150)

        let appDelegateSource = try! String(
            contentsOfFile: "MonoList/App/AppDelegate.swift",
            encoding: .utf8
        )
        precondition(
            appDelegateSource.contains(
                "let focusPresentation = currentFocusReminderPresentation()"
            ),
            "测试提醒也应读取当前专注任务"
        )
        precondition(
            !appDelegateSource.contains("let focusPresentation = testing ? nil"),
            "测试提醒不能跳过专注提醒模式"
        )
        precondition(
            appDelegateSource.contains("ReminderPanelController.tasksForFocusTest"),
            "今日专注全部完成后，测试按钮仍应展示专注提醒示例"
        )
        let testReminderStart = appDelegateSource.range(of: "onTestReminder: { [weak self] in")!
        let testReminderEnd = appDelegateSource.range(
            of: "\n            }\n        )",
            range: testReminderStart.lowerBound..<appDelegateSource.endIndex
        )!
        let testReminderHandler = appDelegateSource[
            testReminderStart.lowerBound..<testReminderEnd.upperBound
        ]
        precondition(!testReminderHandler.contains("isTesting"))
        precondition(testReminderHandler.contains("showReminder(testing: true)"))

        guard !NSScreen.screens.isEmpty else {
            print("Reminder scheduler smoke passed (界面用例因无可用屏幕而跳过).")
            return
        }

        var playedSounds: [String] = []
        let controller = ReminderPanelController(playSound: { playedSounds.append($0) })
        controller.show(
            tasks: testTasks,
            position: .topCenter,
            menuBarButton: nil,
            testing: true,
            soundName: "Ping",
            onOpen: {},
            onClose: {}
        )
        precondition(controller.isTesting)
        precondition((controller.currentPanelHeight ?? 0) < 110)
        precondition(playedSounds == ["Ping"])
        controller.close(animated: false)
        controller.show(
            tasks: testTasks,
            position: .topCenter,
            menuBarButton: nil,
            title: "当前专注",
            statusText: "1/1",
            isFocusReminder: true,
            testing: true,
            playsSound: false,
            onOpen: {},
            onClose: {}
        )
        precondition(controller.currentPanelWidth == 420)
        precondition((controller.currentPanelHeight ?? 0) >= 150)
        controller.close(animated: false)
        controller.show(
            tasks: testTasks,
            position: .topCenter,
            menuBarButton: nil,
            testing: true,
            soundName: "Ping",
            onOpen: {},
            onClose: {}
        )
        precondition(
            playedSounds == ["Ping", "Ping"],
            "重复点击测试提醒应每次重新播放声音"
        )
        controller.close(animated: false)
        precondition(!controller.isTesting)
        precondition(playedSounds == ["Ping", "Ping"])
        controller.show(
            tasks: testTasks,
            position: .topCenter,
            menuBarButton: nil,
            testing: true,
            playsSound: false,
            onOpen: {},
            onClose: {}
        )
        precondition(playedSounds == ["Ping", "Ping"])
        controller.close(animated: false)

        print("Reminder scheduler smoke passed.")
    }

    private static func fixedCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func fixedDate(
        dayOffset: Int = 0,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) -> Date {
        let start = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 7,
                day: 7 + dayOffset,
                hour: hour,
                minute: minute
            )
        )!
        return start
    }
}
