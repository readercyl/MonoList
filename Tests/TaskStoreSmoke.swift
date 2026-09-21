import Foundation

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

struct AlwaysFailWriter: AtomicWriting {
    func write(_ data: Data, to destinationURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@main
struct TaskStoreSmoke {
    @MainActor
    static func main() throws {
        try testAddCompleteRestoreAndReload()
        try testEditAndMovePersist()
        try testNestedTasksAndCascadeRules()
        try testCompleteCommitsPendingTextAtomically()
        try testExplicitReorderPersists()
        try testLegacyTasksDefaultToShortTerm()
        try testLegacyGroupsMergeIntoUnifiedOrder()
        try testStableHistoryOrder()
        try testTodayAndOlderCompletedTasks()
        try testOneTimeReminderPersistsAndClears()
        try testCountdownAndScheduledDateConstruction()
        try testDailyReminderReappearsAfterMidnight()
        try testDeleteAndClearScopes()
        try testWriteFailureKeepsCommittedState()
        try testUnknownSchemaDoesNotOverwriteFile()
        try testDamagedFileDoesNotGetOverwritten()
        print("Task store smoke passed.")
    }

    @MainActor
    private static func testAddCompleteRestoreAndReload() throws {
        let fixture = try Fixture()
        let store = TaskStore(fileURL: fixture.fileURL)
        let first = try store.add(text: "第一条")
        let second = try store.add(text: "第二条", after: first.id)
        let third = try store.add(text: "第三条")

        try require(store.pendingTasks.map(\.text) == ["第一条", "第二条", "第三条"],
                    "新增位置不正确")

        let completionDate = Date(timeIntervalSince1970: 100)
        try store.complete(id: second.id, at: completionDate)
        try require(store.pendingTasks.map(\.text) == ["第一条", "第三条"],
                    "完成任务后主列表不正确")
        try require(store.historyTasks.map(\.text) == ["第二条"],
                    "完成任务没有进入历史记录")

        try store.restore(id: second.id, at: Date(timeIntervalSince1970: 200))
        try require(store.pendingTasks.map(\.id) == [first.id, third.id, second.id],
                    "恢复任务没有加入主列表底部")

        let reloaded = TaskStore(fileURL: fixture.fileURL)
        try require(reloaded.pendingTasks.map(\.id) == [first.id, third.id, second.id],
                    "重启后任务顺序没有保持")
    }

    @MainActor
    private static func testEditAndMovePersist() throws {
        let fixture = try Fixture()
        let store = TaskStore(fileURL: fixture.fileURL)
        let first = try store.add(text: "第一条")
        let second = try store.add(text: "第二条")
        try store.updateText(id: first.id, text: "修改后", at: Date(timeIntervalSince1970: 50))
        try store.move(id: second.id, by: -1)

        try require(store.pendingTasks.map(\.text) == ["第二条", "修改后"],
                    "编辑或排序结果不正确")

        let reloaded = TaskStore(fileURL: fixture.fileURL)
        try require(reloaded.pendingTasks.map(\.text) == ["第二条", "修改后"],
                    "编辑或排序没有持久化")
    }

    @MainActor
    private static func testNestedTasksAndCascadeRules() throws {
        let fixture = try Fixture()
        let store = TaskStore(fileURL: fixture.fileURL)
        let parent = try store.add(text: "发布主页")
        let firstChild = try store.add(
            text: "完成主页布局",
            after: nil,
            group: .shortTerm,
            parentID: parent.id
        )
        let secondChild = try store.add(
            text: "补齐窗口行为",
            after: firstChild.id,
            group: .shortTerm,
            parentID: parent.id
        )

        try require(store.children(of: parent.id).map(\.id) == [firstChild.id, secondChild.id],
                    "子任务顺序不正确")
        try require(store.topLevelPendingTasks.map(\.id) == [parent.id],
                    "子任务不应出现在一级任务列表")

        try store.complete(id: firstChild.id)
        try require(store.subtaskProgressText(for: parent.id) == "1/2 已完成",
                    "父任务没有显示子任务完成进度")
        try require(store.pendingTasks.map(\.id) == [parent.id, secondChild.id],
                    "子任务单独完成时影响了父任务")
        try require(store.historyTasks.map(\.id) == [firstChild.id],
                    "子任务单独完成没有进入已完成")

        try store.complete(id: parent.id)
        try require(store.pendingTasks.isEmpty,
                    "完成父任务后仍有未完成的子任务")
        try require(Set(store.historyTasks.map(\.id)) ==
                        Set([parent.id, firstChild.id, secondChild.id]),
                    "完成父任务没有级联完成全部子任务")

        let reloaded = TaskStore(fileURL: fixture.fileURL)
        try require(reloaded.children(of: parent.id).map(\.id) ==
                        [firstChild.id, secondChild.id],
                    "重启后父子层级没有保持")

        try reloaded.restore(id: parent.id)
        try require(reloaded.pendingTasks.map(\.id).count == 3,
                    "恢复父任务没有恢复子任务")
        try reloaded.delete(id: parent.id)
        try require(reloaded.tasks.isEmpty,
                    "删除父任务没有级联删除全部子任务")

        let indentStore = TaskStore(
            fileURL: fixture.directoryURL.appendingPathComponent("indent.json")
        )
        let firstRoot = try indentStore.add(text: "第一项")
        let secondRoot = try indentStore.add(text: "第二项")
        try indentStore.indent(id: secondRoot.id)
        try require(indentStore.children(of: firstRoot.id).map(\.id) == [secondRoot.id],
                    "Tab 缩进没有建立子任务层级")
        try indentStore.outdent(id: secondRoot.id)
        try require(indentStore.topLevelPendingTasks.map(\.id) ==
                        [firstRoot.id, secondRoot.id],
                    "退格回退没有恢复一级任务")

        let hierarchyParent = try indentStore.add(text: "层级父任务")
        let hierarchyChild = try indentStore.add(
            text: "层级子任务",
            group: .shortTerm,
            parentID: hierarchyParent.id
        )
        do {
            _ = try indentStore.add(
                text: "不允许的三级任务",
                group: .shortTerm,
                parentID: hierarchyChild.id
            )
            throw TestFailure.failed("不应允许创建三级任务")
        } catch TaskStoreError.invalidHierarchy {
            // 预期失败。
        }

    }

    @MainActor
    private static func testCompleteCommitsPendingTextAtomically() throws {
        let fixture = try Fixture()
        let store = TaskStore(fileURL: fixture.fileURL)
        let item = try store.add(text: "旧内容")
        try store.complete(id: item.id, finalText: "最终内容",
                           at: Date(timeIntervalSince1970: 75))

        try require(store.pendingTasks.isEmpty, "原子完成后任务仍在主列表")
        try require(store.historyTasks.map(\.text) == ["最终内容"],
                    "完成时没有一起保存最终文本")
    }

    @MainActor
    private static func testExplicitReorderPersists() throws {
        let fixture = try Fixture()
        let store = TaskStore(fileURL: fixture.fileURL)
        let first = try store.add(text: "一")
        let second = try store.add(text: "二")
        let third = try store.add(text: "三")
        try store.reorder(ids: [third.id, first.id, second.id])

        try require(store.pendingTasks.map(\.id) == [third.id, first.id, second.id],
                    "拖动排序结果不正确")
        let reloaded = TaskStore(fileURL: fixture.fileURL)
        try require(reloaded.pendingTasks.map(\.id) == [third.id, first.id, second.id],
                    "拖动排序没有持久化")
    }

    @MainActor
    private static func testLegacyTasksDefaultToShortTerm() throws {
        let fixture = try Fixture()
        let taskID = UUID()
        let data = Data(
            """
            {"schemaVersion":1,"tasks":[{"id":"\(taskID.uuidString)","text":"旧任务","status":"pending","order":0,"createdAt":"1970-01-01T00:00:00Z","updatedAt":"1970-01-01T00:00:00Z","completedAt":null,"reminder":null}]}
            """.utf8
        )
        try data.write(to: fixture.fileURL)
        let store = TaskStore(fileURL: fixture.fileURL)
        try require(store.loadError == nil, "旧任务数据无法读取")
        try require(store.shortTermTasks.map(\.id) == [taskID], "旧任务没有默认归入短期")
        try require(store.longTermTasks.isEmpty, "旧任务错误归入长期")
        try store.updateText(id: taskID, text: "迁移后的任务")
        let migratedData = try Data(contentsOf: fixture.fileURL)
        let migratedObject = try JSONSerialization.jsonObject(with: migratedData)
        let migratedSchema = (migratedObject as? [String: Any])?["schemaVersion"] as? Int
        try require(migratedSchema == TaskDatabase.currentSchemaVersion,
                    "旧任务写入后没有升级数据版本")
    }

    @MainActor
    private static func testLegacyGroupsMergeIntoUnifiedOrder() throws {
        let fixture = try Fixture()
        let shortID = UUID()
        let longID = UUID()
        let data = Data(
            """
            {
              "schemaVersion": 2,
              "tasks": [
                {"id":"\(longID.uuidString)","text":"旧长期","status":"pending","order":0,"createdAt":"1970-01-01T00:00:00Z","updatedAt":"1970-01-01T00:00:00Z","completedAt":null,"reminder":null,"group":"longTerm"},
                {"id":"\(shortID.uuidString)","text":"旧短期","status":"pending","order":0,"createdAt":"1970-01-01T00:00:00Z","updatedAt":"1970-01-01T00:00:00Z","completedAt":null,"reminder":null,"group":"shortTerm"}
              ]
            }
            """.utf8
        )
        try data.write(to: fixture.fileURL)
        let store = TaskStore(fileURL: fixture.fileURL)
        try require(
            store.pendingTasks.map(\.text) == ["旧短期", "旧长期"],
            "旧分组任务没有合并为统一顺序"
        )
        try require(store.pendingTasks.allSatisfy { $0.group == .shortTerm },
                    "旧分组字段没有降级为兼容值")
        let appended = try store.add(text: "新任务")
        try require(store.pendingTasks.map(\.id).last == appended.id,
                    "统一列表新增任务没有追加到末尾")
    }

    @MainActor
    private static func testStableHistoryOrder() throws {
        let fixture = try Fixture()
        let store = TaskStore(fileURL: fixture.fileURL)
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        ]

        for (index, id) in ids.enumerated() {
            _ = try store.add(
                text: "任务\(index)",
                id: id,
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
            try store.complete(id: id, at: Date(timeIntervalSince1970: 300))
        }

        try require(store.historyTasks.map(\.id) == [ids[1], ids[0]],
                    "相同完成时间没有按稳定任务 ID 升序排列")
    }

    @MainActor
    private static func testTodayAndOlderCompletedTasks() throws {
        let fixture = try Fixture()
        let store = TaskStore(fileURL: fixture.fileURL)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let today = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 6, hour: 12)
        )!
        let todayTask = try store.add(text: "今天创建完成", createdAt: today)
        let createdYesterday = try store.add(
            text: "昨天创建今天完成",
            createdAt: today.addingTimeInterval(-24 * 60 * 60)
        )

        try store.complete(id: todayTask.id, at: today.addingTimeInterval(60))
        try store.complete(id: createdYesterday.id, at: today.addingTimeInterval(120))

        try require(
            store.completedTasks(on: today, calendar: calendar).map(\.id) ==
                [createdYesterday.id, todayTask.id],
            "今天完成的任务没有全部默认显示"
        )
        try require(
            store.completedTasks(before: today, calendar: calendar).isEmpty,
            "今天完成的任务被错误归入较早记录"
        )

        let tomorrow = today.addingTimeInterval(24 * 60 * 60)
        try require(
            store.completedTasks(on: tomorrow, calendar: calendar).isEmpty,
            "跨日后今天的完成项仍被当作明日完成项"
        )
        try require(
            store.completedTasks(before: tomorrow, calendar: calendar).map(\.id) ==
                [createdYesterday.id, todayTask.id],
            "完成项跨日后没有自动归入较早记录"
        )
    }

    @MainActor
    private static func testOneTimeReminderPersistsAndClears() throws {
        let fixture = try Fixture()
        let store = TaskStore(fileURL: fixture.fileURL)
        let item = try store.add(text: "晚上六点提醒")
        let reminderDate = Date(timeIntervalSince1970: 18 * 60 * 60)

        try store.updateReminder(
            id: item.id,
            reminder: TaskReminder.once(at: reminderDate),
            at: Date(timeIntervalSince1970: 10)
        )

        let reloaded = TaskStore(fileURL: fixture.fileURL)
        try require(
            reloaded.pendingTasks.first?.reminder == .once(at: reminderDate),
            "一次性单条提醒没有持久化"
        )

        try reloaded.clearTriggeredOneTimeReminder(
            id: item.id,
            at: Date(timeIntervalSince1970: 20)
        )
        try require(
            reloaded.pendingTasks.first?.reminder == nil,
            "一次性单条提醒触发后没有清除"
        )
    }

    private static func testCountdownAndScheduledDateConstruction() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        try require(TaskReminder.countdown(minutes: 20, from: now) ==
            .once(at: Date(timeIntervalSince1970: 2_200)),
            "倒计时没有换算为绝对触发时间")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let day = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14))!
        let expected = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 14, hour: 18, minute: 30)
        )!
        try require(TaskReminder.once(on: day, minuteOfDay: 18 * 60 + 30,
                                      calendar: calendar) == .once(at: expected),
                    "指定日期时间构造不正确")
        try require(TaskReminder.once(on: day, minuteOfDay: 24 * 60,
                                      calendar: calendar) == nil,
                    "越界时间不应生成提醒")
    }

    @MainActor
    private static func testDailyReminderReappearsAfterMidnight() throws {
        let fixture = try Fixture()
        let store = TaskStore(fileURL: fixture.fileURL)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let dayOne = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 7, hour: 9)
        )!
        let dayTwo = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 8, hour: 0, minute: 1)
        )!
        let item = try store.add(text: "每天喝水", createdAt: dayOne)
        let reminderID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        try store.updateReminder(
            id: item.id,
            reminder: TaskReminder.daily(minuteOfDay: 18 * 60, id: reminderID),
            at: dayOne
        )
        try store.complete(id: item.id, at: dayOne.addingTimeInterval(60))

        try store.refreshDailyReminderTasks(at: dayTwo, calendar: calendar)
        try require(store.pendingTasks.count == 1, "每日提醒任务过 0 点后没有重新出现")
        try require(store.historyTasks.count == 1, "每日提醒重新出现时不应删除昨天的完成记录")
        try require(store.pendingTasks[0].text == "每天喝水", "每日提醒重新出现的文本不正确")
        try require(
            store.pendingTasks[0].reminder == .daily(minuteOfDay: 18 * 60, id: reminderID),
            "每日提醒重新出现后没有保留提醒规则"
        )

        try store.refreshDailyReminderTasks(at: dayTwo.addingTimeInterval(60), calendar: calendar)
        try require(store.pendingTasks.count == 1, "每日提醒任务同一天不应重复生成")

        let todayTaskID = store.pendingTasks[0].id
        try store.complete(id: todayTaskID, at: dayTwo.addingTimeInterval(10 * 60 * 60))
        try store.refreshDailyReminderTasks(
            at: dayTwo.addingTimeInterval(10 * 60 * 60 + 60),
            calendar: calendar
        )
        try require(store.pendingTasks.isEmpty, "每日提醒任务今天完成后不应同一天再次出现")

        try store.refreshDailyReminderTasks(
            at: dayTwo.addingTimeInterval(24 * 60 * 60 + 60),
            calendar: calendar
        )
        try require(store.pendingTasks.count == 1, "每日提醒任务第二天应再次出现")
        try store.delete(id: store.pendingTasks[0].id)
        try store.refreshDailyReminderTasks(
            at: dayTwo.addingTimeInterval(2 * 24 * 60 * 60 + 60),
            calendar: calendar
        )
        try require(store.pendingTasks.isEmpty, "删除每日提醒任务后不应再次生成")

        let clearStore = TaskStore(
            fileURL: fixture.directoryURL.appendingPathComponent("clear-pending.json")
        )
        let clearItem = try clearStore.add(text: "每天站立", createdAt: dayOne)
        try clearStore.updateReminder(
            id: clearItem.id,
            reminder: .daily(minuteOfDay: 10 * 60),
            at: dayOne
        )
        try clearStore.complete(id: clearItem.id, at: dayOne.addingTimeInterval(60))
        try clearStore.refreshDailyReminderTasks(at: dayTwo, calendar: calendar)
        try clearStore.clearPending()
        try clearStore.refreshDailyReminderTasks(
            at: dayTwo.addingTimeInterval(24 * 60 * 60 + 60),
            calendar: calendar
        )
        try require(clearStore.pendingTasks.isEmpty, "清空未完成后每日提醒任务不应再次生成")
    }

    @MainActor
    private static func testDeleteAndClearScopes() throws {
        let fixture = try Fixture()
        let store = TaskStore(fileURL: fixture.fileURL)
        let pending = try store.add(text: "未完成")
        let history = try store.add(text: "已完成")
        try store.complete(id: history.id)
        try store.delete(id: pending.id)
        try require(store.pendingTasks.isEmpty, "单条删除失败")
        try require(store.historyTasks.count == 1, "单条删除影响了历史记录")

        _ = try store.add(text: "保留前清空")
        try store.clearPending()
        try require(store.pendingTasks.isEmpty && store.historyTasks.count == 1,
                    "清空主列表范围不正确")

        try store.clearHistory()
        try require(store.historyTasks.isEmpty, "清空历史记录失败")

        _ = try store.add(text: "全部清空")
        try store.clearAll()
        try require(store.pendingTasks.isEmpty && store.historyTasks.isEmpty,
                    "清空全部任务失败")
    }

    @MainActor
    private static func testWriteFailureKeepsCommittedState() throws {
        let fixture = try Fixture()
        let seedStore = TaskStore(fileURL: fixture.fileURL)
        _ = try seedStore.add(text: "已提交")
        let oldData = try Data(contentsOf: fixture.fileURL)

        let failingStore = TaskStore(fileURL: fixture.fileURL, writer: AlwaysFailWriter())
        do {
            _ = try failingStore.add(text: "不能保存")
            throw TestFailure.failed("写入失败时操作不应成功")
        } catch is CocoaError {
            // 预期失败。
        }

        try require(failingStore.pendingTasks.map(\.text) == ["已提交"],
                    "写入失败后界面状态没有恢复")
        try require(failingStore.isWritePaused, "写入失败后没有暂停修改")
        try require(try Data(contentsOf: fixture.fileURL) == oldData,
                    "写入失败覆盖了原文件")
    }

    @MainActor
    private static func testUnknownSchemaDoesNotOverwriteFile() throws {
        let fixture = try Fixture()
        let original = Data(#"{"schemaVersion":99,"tasks":[]}"#.utf8)
        try original.write(to: fixture.fileURL)

        let store = TaskStore(fileURL: fixture.fileURL)
        try require(store.loadError != nil, "未知 schemaVersion 没有进入恢复状态")
        try require(try Data(contentsOf: fixture.fileURL) == original,
                    "未知 schemaVersion 文件被覆盖")

        do {
            _ = try store.add(text: "禁止写入")
            throw TestFailure.failed("恢复状态下不应允许修改")
        } catch is TaskStoreError {
            // 预期失败。
        }

        let validStore = TaskStore(
            fileURL: fixture.directoryURL.appendingPathComponent("valid.json")
        )
        _ = try validStore.add(text: "恢复后的数据")
        let validData = try Data(
            contentsOf: fixture.directoryURL.appendingPathComponent("valid.json")
        )
        try validData.write(to: fixture.fileURL)
        store.retryLoad()
        try require(store.loadError == nil, "修复文件后重试读取没有恢复")
        try require(store.pendingTasks.map(\.text) == ["恢复后的数据"],
                    "重试读取没有加载修复后的数据")
    }

    @MainActor
    private static func testDamagedFileDoesNotGetOverwritten() throws {
        let fixture = try Fixture()
        let original = Data("不是有效的 JSON".utf8)
        try original.write(to: fixture.fileURL)

        let store = TaskStore(fileURL: fixture.fileURL)
        try require(store.loadError != nil, "损坏文件没有进入恢复状态")
        try require(try Data(contentsOf: fixture.fileURL) == original,
                    "损坏文件被覆盖")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool,
                                _ message: String) throws {
        guard try condition() else {
            throw TestFailure.failed(message)
        }
    }
}

private struct Fixture {
    let directoryURL: URL
    let fileURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListTaskStoreTests-\(UUID().uuidString)")
        fileURL = directoryURL.appendingPathComponent("tasks.json")
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }
}
