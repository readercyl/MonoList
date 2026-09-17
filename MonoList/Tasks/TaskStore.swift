import Combine
import Foundation

enum TaskStoreError: LocalizedError {
    case emptyText
    case invalidSchemaVersion
    case missingTask
    case invalidOrder
    case invalidReminder
    case invalidHierarchy
    case recoveryRequired
    case writePaused

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "待办内容不能为空"
        case .invalidSchemaVersion:
            return "任务数据版本无法读取"
        case .missingTask:
            return "找不到这条待办"
        case .invalidOrder:
            return "待办排序数据无效"
        case .invalidReminder:
            return "提醒时间无效"
        case .invalidHierarchy:
            return "任务层级数据无效"
        case .recoveryRequired:
            return "任务数据读取失败，请重试"
        case .writePaused:
            return "保存已暂停，请重试"
        }
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var loadError: Error?
    @Published private(set) var isWritePaused = false

    private let fileURL: URL
    private let writer: any AtomicWriting
    private var needsMigration = false

    var pendingTasks: [TaskItem] {
        tasks
            .filter { $0.status == .pending }
            .sorted {
                if $0.group != $1.group {
                    return $0.group == .shortTerm
                }
                if $0.order != $1.order {
                    return $0.order < $1.order
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    var shortTermTasks: [TaskItem] {
        pendingTasks.filter { $0.group == .shortTerm }
    }

    var longTermTasks: [TaskItem] {
        pendingTasks.filter { $0.group == .longTerm }
    }

    var topLevelPendingTasks: [TaskItem] {
        pendingTasks.filter { $0.parentID == nil }
    }

    func topLevelPendingTasks(in group: TaskGroup) -> [TaskItem] {
        pendingTasks.filter { $0.group == group && $0.parentID == nil }
    }

    func children(of parentID: UUID) -> [TaskItem] {
        tasks
            .filter { $0.parentID == parentID }
            .sorted(by: Self.taskOrder)
    }

    func subtaskProgressText(for parentID: UUID) -> String? {
        let subtasks = children(of: parentID)
        guard !subtasks.isEmpty else { return nil }
        let completedCount = subtasks.filter { $0.status == .history }.count
        return "\(completedCount)/\(subtasks.count) 已完成"
    }

    var historyTasks: [TaskItem] {
        tasks
            .filter { $0.status == .history }
            .sorted {
                let lhsDate = $0.completedAt ?? .distantPast
                let rhsDate = $1.completedAt ?? .distantPast
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    func completedTasks(
        on date: Date,
        calendar: Calendar = .current
    ) -> [TaskItem] {
        historyTasks.filter {
            calendar.isDate($0.completedAt ?? $0.updatedAt, inSameDayAs: date)
        }
    }

    func completedTasks(
        before date: Date,
        calendar: Calendar = .current
    ) -> [TaskItem] {
        let startOfDay = calendar.startOfDay(for: date)
        return historyTasks.filter {
            ($0.completedAt ?? $0.updatedAt) < startOfDay
        }
    }

    init(fileURL: URL, writer: any AtomicWriting = AtomicFileWriter()) {
        self.fileURL = fileURL
        self.writer = writer
        load()
    }

    @discardableResult
    func add(
        text: String,
        after previousID: UUID? = nil,
        group: TaskGroup = .shortTerm,
        parentID: UUID? = nil,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> TaskItem {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            throw TaskStoreError.emptyText
        }

        try validateParentID(parentID, group: group, in: tasks)

        var candidate = tasks
        var pending = tasks(in: group)
        let insertionIndex = insertionIndex(
            after: previousID,
            parentID: parentID,
            in: pending
        )

        let item = TaskItem(
            id: id,
            text: normalizedText,
            status: .pending,
            order: insertionIndex,
            createdAt: createdAt,
            updatedAt: createdAt,
            completedAt: nil,
            group: group,
            parentID: parentID
        )
        pending.insert(item, at: insertionIndex)
        normalizeOrders(in: &pending)
        candidate.removeAll { $0.status == .pending && $0.group == group }
        candidate.append(contentsOf: pending)
        try commit(candidate)
        return item
    }

    func complete(id: UUID, at date: Date = Date()) throws {
        try completeTaskAndChildren(id: id, finalText: nil, at: date)
    }

    func complete(id: UUID, finalText: String, at date: Date = Date()) throws {
        let normalizedText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        try completeTaskAndChildren(
            id: id,
            finalText: normalizedText.isEmpty ? nil : normalizedText,
            at: date
        )
    }

    func setParent(
        id: UUID,
        parentID: UUID?,
        at date: Date = Date()
    ) throws {
        try guardAvailable()
        var candidate = tasks
        guard let item = candidate.first(where: { $0.id == id }) else {
            throw TaskStoreError.missingTask
        }
        guard item.status == .pending else {
            throw TaskStoreError.invalidHierarchy
        }
        if parentID == id {
            throw TaskStoreError.invalidHierarchy
        }
        try validateParentID(parentID, group: item.group, in: candidate)

        let oldParentID = item.parentID
        guard oldParentID != parentID else { return }
        let sourceGroup = item.group
        var pending = pendingTasks(in: candidate, group: sourceGroup)
        let subtreeIDs = Set(
            [id] + candidate
                .filter { $0.parentID == id }
                .map(\.id)
        )
        let movingItems = pending.filter { subtreeIDs.contains($0.id) }
        pending.removeAll { subtreeIDs.contains($0.id) }

        var updatedMovingItems = movingItems
        if let movedRootIndex = updatedMovingItems.firstIndex(where: { $0.id == id }) {
            updatedMovingItems[movedRootIndex].parentID = parentID
            updatedMovingItems[movedRootIndex].updatedAt = date
        }
        let insertionIndex: Int
        if let parentID {
            let destinationChildren = pending.filter { $0.parentID == parentID }
            if let lastChild = destinationChildren.last,
               let insertion = subtreeEndIndex(for: lastChild.id, in: pending) {
                insertionIndex = insertion + 1
            } else if let insertion = subtreeEndIndex(for: parentID, in: pending) {
                insertionIndex = insertion + 1
            } else {
                insertionIndex = pending.endIndex
            }
        } else if let oldParentID,
                  let insertion = subtreeEndIndex(for: oldParentID, in: pending) {
            insertionIndex = insertion + 1
        } else {
            insertionIndex = pending.endIndex
        }
        pending.insert(contentsOf: updatedMovingItems, at: insertionIndex)

        candidate.removeAll { $0.status == .pending && $0.group == sourceGroup }
        candidate.append(contentsOf: pending)
        normalizePendingOrders(in: &candidate)
        try commit(candidate)
    }

    func indent(id: UUID, at date: Date = Date()) throws {
        try guardAvailable()
        guard let item = tasks.first(where: { $0.id == id && $0.status == .pending }),
              item.parentID == nil else {
            return
        }
        let roots = topLevelPendingTasks(in: item.group)
        guard let index = roots.firstIndex(where: { $0.id == id }), index > 0 else {
            return
        }
        try setParent(id: id, parentID: roots[index - 1].id, at: date)
    }

    func outdent(id: UUID, at date: Date = Date()) throws {
        try guardAvailable()
        guard let item = tasks.first(where: { $0.id == id && $0.status == .pending }),
              item.parentID != nil else {
            return
        }
        try setParent(id: id, parentID: nil, at: date)
    }

    private func completeTaskAndChildren(
        id: UUID,
        finalText: String?,
        at date: Date
    ) throws {
        try guardAvailable()
        var candidate = tasks
        guard let item = candidate.first(where: { $0.id == id }) else {
            throw TaskStoreError.missingTask
        }
        if let finalText,
           let index = candidate.firstIndex(where: { $0.id == id }) {
            candidate[index].text = finalText
        }

        let idsToComplete: Set<UUID>
        if item.parentID == nil {
            idsToComplete = Set(
                [item.id] + candidate
                    .filter { $0.parentID == item.id }
                    .map(\.id)
            )
        } else {
            idsToComplete = [item.id]
        }
        for index in candidate.indices where idsToComplete.contains(candidate[index].id) {
            guard candidate[index].status == .pending else { continue }
            candidate[index].status = .history
            candidate[index].updatedAt = date
            candidate[index].completedAt = date
        }
        normalizePendingOrders(in: &candidate)
        try commit(candidate)
    }

    func updateText(id: UUID, text: String, at date: Date = Date()) throws {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            throw TaskStoreError.emptyText
        }
        try mutateTask(id: id) { item in
            item.text = normalizedText
            item.updatedAt = date
        }
    }

    func updateReminder(
        id: UUID,
        reminder: TaskReminder?,
        at date: Date = Date()
    ) throws {
        if let reminder {
            try validate(reminder)
        }
        try mutateTask(id: id) { item in
            item.reminder = reminder
            item.updatedAt = date
        }
    }

    func clearTriggeredOneTimeReminder(
        id: UUID,
        at date: Date = Date()
    ) throws {
        try mutateTask(id: id) { item in
            if item.reminder?.kind == .once {
                item.reminder = nil
                item.updatedAt = date
            }
        }
    }

    func markDedicatedReminderTriggered(
        id: UUID,
        at date: Date = Date()
    ) throws {
        try mutateTask(id: id) { item in
            guard var reminder = item.reminder else { return }
            switch reminder.kind {
            case .once:
                item.reminder = nil
            case .daily:
                reminder.lastTriggeredAt = date
                item.reminder = reminder
            }
            item.updatedAt = date
        }
    }

    func refreshDailyReminderTasks(
        at date: Date = Date(),
        calendar: Calendar = .current
    ) throws {
        try guardAvailable()
        let startOfToday = calendar.startOfDay(for: date)
        var candidate = tasks
        let dailyGroups = Dictionary(
            grouping: candidate.filter {
                $0.reminder?.kind == .daily &&
                    $0.reminder?.recurrenceID != nil
            },
            by: { $0.reminder!.recurrenceID! }
        )
        guard !dailyGroups.isEmpty else { return }

        var pending = pendingTasks
        var didChange = false
        let orderedDailyGroups = dailyGroups.values.compactMap { group -> (TaskItem, [TaskItem])? in
            guard let source = group.max(by: { lhs, rhs in
                let lhsDate = lhs.completedAt ?? lhs.updatedAt
                let rhsDate = rhs.completedAt ?? rhs.updatedAt
                if lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }) else {
                return nil
            }
            return (source, group)
        }.sorted { lhs, rhs in
            (lhs.0.parentID == nil ? 0 : 1) < (rhs.0.parentID == nil ? 0 : 1)
        }
        var dailyCloneIDs: [UUID: UUID] = [:]
        for (source, reminderTaskGroup) in orderedDailyGroups {
            if reminderTaskGroup.contains(where: { $0.status == .pending }) {
                continue
            }
            if calendar.startOfDay(for: source.createdAt) >= startOfToday {
                continue
            }
            var reminder = source.reminder
            if reminder?.kind == .daily,
               let lastTriggeredAt = reminder?.lastTriggeredAt,
               calendar.startOfDay(for: lastTriggeredAt) >= startOfToday {
                reminder?.lastTriggeredAt = nil
            }
            let parentID = source.parentID.flatMap { parentID in
                dailyCloneIDs[parentID] ?? candidate.first(where: {
                    $0.id == parentID && $0.status == .pending
                })?.id
            }
            let newID = UUID()
            let item = TaskItem(
                id: newID,
                text: source.text,
                status: .pending,
                order: pending.count,
                createdAt: date,
                updatedAt: date,
                completedAt: nil,
                reminder: reminder,
                group: source.group,
                parentID: parentID
            )
            pending.append(item)
            if source.parentID == nil {
                dailyCloneIDs[source.id] = newID
            }
            didChange = true
        }
        guard didChange else { return }

        normalizeOrders(in: &pending)
        candidate.removeAll { $0.status == .pending }
        candidate.append(contentsOf: pending)
        try commit(candidate)
    }

    func move(id: UUID, by offset: Int) throws {
        try guardAvailable()
        guard offset != 0 else {
            return
        }

        guard let item = tasks.first(where: { $0.id == id && $0.status == .pending }) else {
            throw TaskStoreError.missingTask
        }
        let group = item.group
        var pending = pendingTasks(in: tasks, group: group)
        let siblings = pending.filter { $0.parentID == item.parentID }
        guard let sourceIndex = siblings.firstIndex(where: { $0.id == id }) else {
            throw TaskStoreError.missingTask
        }
        let destinationIndex = min(
            max(sourceIndex + offset, siblings.startIndex),
            siblings.index(before: siblings.endIndex)
        )
        guard sourceIndex != destinationIndex else {
            return
        }

        let subtreeIDs = Set(
            [id] + pending
                .filter { $0.parentID == id }
                .map(\.id)
        )
        let movingItems = pending.filter { subtreeIDs.contains($0.id) }
        pending.removeAll { subtreeIDs.contains($0.id) }
        let destinationID = siblings[destinationIndex].id
        let insertionIndex: Int
        if offset < 0 {
            insertionIndex = pending.firstIndex(where: { $0.id == destinationID }) ??
                pending.endIndex
        } else {
            insertionIndex = subtreeEndIndex(for: destinationID, in: pending)
                .map { $0 + 1 } ?? pending.endIndex
        }
        pending.insert(contentsOf: movingItems, at: insertionIndex)
        normalizeOrders(in: &pending)

        var candidate = tasks.filter { !($0.status == .pending && $0.group == group) }
        candidate.append(contentsOf: pending)
        try commit(candidate)
    }

    func move(
        id: UUID,
        to group: TaskGroup,
        before destinationID: UUID?,
        parentID: UUID? = nil
    ) throws {
        try guardAvailable()
        guard let selectedItem = tasks.first(where: { $0.id == id && $0.status == .pending }) else {
            throw TaskStoreError.missingTask
        }
        if let parentID {
            try moveChild(
                selectedItem,
                within: parentID,
                before: destinationID
            )
            return
        }
        let rootID = selectedItem.parentID ?? selectedItem.id
        let rootItem = tasks.first(where: { $0.id == rootID }) ?? selectedItem
        let destinationRootID = destinationID.flatMap { destinationID in
            tasks.first(where: { $0.id == destinationID }).map {
                $0.parentID ?? $0.id
            }
        }
        if destinationRootID == rootID { return }

        let subtreeIDs = Set(
            [rootID] + tasks
                .filter { $0.parentID == rootID }
                .map(\.id)
        )
        var movedItems = pendingTasks(in: tasks, group: rootItem.group)
            .filter { subtreeIDs.contains($0.id) }
        for index in movedItems.indices {
            movedItems[index].group = group
        }

        var sourceGroup = pendingTasks(in: tasks, group: rootItem.group)
            .filter { !subtreeIDs.contains($0.id) }
        var destinationGroup = rootItem.group == group
            ? sourceGroup
            : pendingTasks(in: tasks, group: group)
        let insertionIndex = destinationRootID.flatMap { destinationRootID in
            destinationGroup.firstIndex(where: { $0.id == destinationRootID })
        } ?? destinationGroup.endIndex
        destinationGroup.insert(contentsOf: movedItems, at: insertionIndex)
        normalizeOrders(in: &destinationGroup)
        normalizeOrders(in: &sourceGroup)

        var candidate = tasks.filter { $0.status != .pending }
        for candidateGroup in TaskGroup.allCases {
            if candidateGroup == group {
                candidate.append(contentsOf: destinationGroup)
            } else if candidateGroup == rootItem.group {
                candidate.append(contentsOf: sourceGroup)
            } else {
                candidate.append(contentsOf: pendingTasks(in: tasks, group: candidateGroup))
            }
        }
        for index in candidate.indices where subtreeIDs.contains(candidate[index].id) {
            candidate[index].group = group
        }
        normalizePendingOrders(in: &candidate)
        try commit(candidate)
    }

    private func moveChild(
        _ item: TaskItem,
        within parentID: UUID,
        before destinationID: UUID?
    ) throws {
        guard item.parentID == parentID,
              item.group == tasks.first(where: { $0.id == parentID })?.group else {
            throw TaskStoreError.invalidHierarchy
        }
        if destinationID == item.id { return }
        if let destinationID,
           tasks.first(where: { $0.id == destinationID })?.parentID != parentID {
            throw TaskStoreError.invalidHierarchy
        }

        var pending = pendingTasks(in: tasks, group: item.group)
        let subtreeIDs = Set(
            [item.id] + pending
                .filter { $0.parentID == item.id }
                .map(\.id)
        )
        let movingItems = pending.filter { subtreeIDs.contains($0.id) }
        pending.removeAll { subtreeIDs.contains($0.id) }
        let insertionIndex = destinationID.flatMap { destinationID in
            pending.firstIndex(where: { $0.id == destinationID })
        } ?? pending.endIndex
        pending.insert(contentsOf: movingItems, at: insertionIndex)
        normalizeOrders(in: &pending)

        var candidate = tasks.filter {
            !($0.status == .pending && $0.group == item.group)
        }
        candidate.append(contentsOf: pending)
        normalizePendingOrders(in: &candidate)
        try commit(candidate)
    }

    func reorder(ids: [UUID]) throws {
        try guardAvailable()
        let pending = pendingTasks
        guard ids.count == pending.count,
              Set(ids) == Set(pending.map(\.id)) else {
            throw TaskStoreError.invalidOrder
        }
        let itemsByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.id, $0) })
        var reordered = try ids.map { id -> TaskItem in
            guard let item = itemsByID[id] else {
                throw TaskStoreError.invalidOrder
            }
            return item
        }
        normalizeOrders(in: &reordered)
        var candidate = tasks.filter { $0.status != .pending }
        candidate.append(contentsOf: reordered)
        try commit(candidate)
    }

    func restore(id: UUID, at date: Date = Date()) throws {
        try guardAvailable()
        var candidate = tasks
        guard let item = candidate.first(where: { $0.id == id }) else {
            throw TaskStoreError.missingTask
        }

        var idsToRestore: Set<UUID> = [item.id]
        if item.parentID == nil {
            idsToRestore.formUnion(
                candidate.filter { $0.parentID == item.id }.map(\.id)
            )
        } else if let parentID = item.parentID,
                  candidate.contains(where: {
                      $0.id == parentID && $0.status == .history
                  }) {
            idsToRestore.insert(parentID)
        }
        var restoringItems = candidate.filter { idsToRestore.contains($0.id) }
        for index in restoringItems.indices where restoringItems[index].status == .history {
            restoringItems[index].status = .pending
            restoringItems[index].updatedAt = date
            restoringItems[index].completedAt = nil
        }
        candidate.removeAll { idsToRestore.contains($0.id) }
        let insertionIndex = candidate.lastIndex {
            $0.status == .pending && $0.group == item.group
        }.map { $0 + 1 } ?? candidate.endIndex
        candidate.insert(contentsOf: restoringItems, at: insertionIndex)
        normalizePendingOrders(in: &candidate)
        try commit(candidate)
    }

    func delete(id: UUID) throws {
        try guardAvailable()
        var candidate = tasks
        guard let item = candidate.first(where: { $0.id == id }) else {
            throw TaskStoreError.missingTask
        }
        let idsToDelete: Set<UUID>
        if item.parentID == nil {
            idsToDelete = Set(
                [item.id] + candidate
                    .filter { $0.parentID == item.id }
                    .map(\.id)
            )
        } else {
            idsToDelete = [item.id]
        }
        let recurrenceIDs = Set(
            candidate
                .filter { idsToDelete.contains($0.id) }
                .compactMap { $0.reminder?.recurrenceID }
        )
        if !recurrenceIDs.isEmpty {
            for index in candidate.indices
            where candidate[index].reminder?.recurrenceID.map(recurrenceIDs.contains) == true {
                candidate[index].reminder = nil
            }
        }
        candidate.removeAll { idsToDelete.contains($0.id) }
        normalizePendingOrders(in: &candidate)
        try commit(candidate)
    }

    func clearPending() throws {
        try guardAvailable()
        var candidate = tasks
        let pendingRootIDs = candidate.compactMap { item -> UUID? in
            guard item.status == .pending, item.parentID == nil else { return nil }
            return item.id
        }
        let cascadedIDs = Set(
            pendingRootIDs + candidate
                .filter { item in
                    item.parentID.map(pendingRootIDs.contains) == true
                }
                .map(\.id)
        )
        let recurrenceIDs = Set(
            candidate.compactMap { item -> UUID? in
                guard item.status == .pending || cascadedIDs.contains(item.id),
                      item.reminder?.kind == .daily else {
                    return nil
                }
                return item.reminder?.recurrenceID
            }
        )
        if !recurrenceIDs.isEmpty {
            for index in candidate.indices
            where candidate[index].reminder?.recurrenceID.map(recurrenceIDs.contains) == true {
                candidate[index].reminder = nil
            }
        }
        candidate.removeAll {
            $0.status == .pending || cascadedIDs.contains($0.id)
        }
        normalizePendingOrders(in: &candidate)
        try commit(candidate)
    }

    func clearHistory() throws {
        try guardAvailable()
        var candidate = tasks
        let historyRootIDs = candidate.compactMap { item -> UUID? in
            guard item.status == .history, item.parentID == nil else { return nil }
            return item.id
        }
        let cascadedIDs = Set(
            candidate
                .filter { item in
                    item.parentID.map(historyRootIDs.contains) == true
                }
                .map(\.id)
        )
        candidate.removeAll {
            $0.status == .history || cascadedIDs.contains($0.id)
        }
        normalizePendingOrders(in: &candidate)
        try commit(candidate)
    }

    func clearAll() throws {
        try clear { _ in true }
    }

    func retryPersist() throws {
        guard loadError == nil else {
            throw TaskStoreError.recoveryRequired
        }
        do {
            try persist(tasks)
            isWritePaused = false
            needsMigration = false
        } catch {
            isWritePaused = true
            throw error
        }
    }

    func retryLoad() {
        tasks = []
        loadError = nil
        isWritePaused = false
        needsMigration = false
        load()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let database = try decoder.decode(TaskDatabase.self, from: data)
            let loadedTasks = database.tasks
            try validateHierarchy(in: loadedTasks)
            tasks = loadedTasks
            needsMigration = database.schemaVersion < TaskDatabase.currentSchemaVersion
            normalizePendingOrders(in: &tasks)
        } catch TaskDatabaseError.invalidSchemaVersion {
            loadError = TaskStoreError.invalidSchemaVersion
        } catch {
            loadError = error
        }
    }

    private func mutateTask(
        id: UUID,
        mutation: (inout TaskItem) -> Void
    ) throws {
        try guardAvailable()
        var candidate = tasks
        guard let index = candidate.firstIndex(where: { $0.id == id }) else {
            throw TaskStoreError.missingTask
        }
        mutation(&candidate[index])
        normalizePendingOrders(in: &candidate)
        try commit(candidate)
    }

    private func clear(where shouldDelete: (TaskItem) -> Bool) throws {
        try guardAvailable()
        var candidate = tasks
        candidate.removeAll(where: shouldDelete)
        normalizePendingOrders(in: &candidate)
        try commit(candidate)
    }

    private func commit(_ candidate: [TaskItem]) throws {
        try guardAvailable()
        do {
            try persist(candidate)
            tasks = candidate
            needsMigration = false
        } catch {
            isWritePaused = true
            throw error
        }
    }

    private func persist(_ candidate: [TaskItem]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(TaskDatabase(tasks: candidate))
        try writer.write(data, to: fileURL)
    }

    private func guardAvailable() throws {
        if loadError != nil {
            throw TaskStoreError.recoveryRequired
        }
        if isWritePaused {
            throw TaskStoreError.writePaused
        }
    }

    private func validate(_ reminder: TaskReminder) throws {
        switch reminder.kind {
        case .once:
            guard reminder.date != nil else {
                throw TaskStoreError.invalidReminder
            }
        case .daily:
            guard (0..<24 * 60).contains(reminder.minuteOfDay),
                  reminder.recurrenceID != nil else {
                throw TaskStoreError.invalidReminder
            }
        }
    }

    private func normalizePendingOrders(in candidate: inout [TaskItem]) {
        for index in candidate.indices {
            candidate[index].order = index
        }
    }

    private func normalizeOrders(in pending: inout [TaskItem]) {
        for index in pending.indices {
            pending[index].order = index
        }
    }

    private func tasks(in group: TaskGroup) -> [TaskItem] {
        pendingTasks(in: tasks, group: group)
    }

    private func pendingTasks(
        in candidate: [TaskItem],
        group: TaskGroup
    ) -> [TaskItem] {
        candidate
            .filter { $0.status == .pending && $0.group == group }
            .sorted(by: Self.taskOrder)
    }

    private static func taskOrder(_ lhs: TaskItem, _ rhs: TaskItem) -> Bool {
        if lhs.order != rhs.order {
            return lhs.order < rhs.order
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func insertionIndex(
        after previousID: UUID?,
        parentID: UUID?,
        in pending: [TaskItem]
    ) -> Int {
        if let previousID,
           let previousEnd = subtreeEndIndex(for: previousID, in: pending) {
            return previousEnd + 1
        }
        if let parentID,
           let lastChild = pending.last(where: { $0.parentID == parentID }),
           let lastChildEnd = subtreeEndIndex(for: lastChild.id, in: pending) {
            return lastChildEnd + 1
        }
        if let parentID,
           let parentEnd = subtreeEndIndex(for: parentID, in: pending) {
            return parentEnd + 1
        }
        return pending.endIndex
    }

    private func subtreeEndIndex(
        for rootID: UUID,
        in items: [TaskItem]
    ) -> Int? {
        let ids = Set(
            [rootID] + items
                .filter { $0.parentID == rootID }
                .map(\.id)
        )
        return items.indices.last(where: { ids.contains(items[$0].id) })
    }

    private func validateParentID(
        _ parentID: UUID?,
        group: TaskGroup,
        in candidate: [TaskItem]
    ) throws {
        guard let parentID else { return }
        guard let parent = candidate.first(where: {
            $0.id == parentID && $0.status == .pending && $0.parentID == nil
        }), parent.group == group else {
            throw TaskStoreError.invalidHierarchy
        }
    }

    private func validateHierarchy(in candidate: [TaskItem]) throws {
        let itemsByID = Dictionary(uniqueKeysWithValues: candidate.map { ($0.id, $0) })
        for item in candidate {
            guard let parentID = item.parentID else { continue }
            guard let parent = itemsByID[parentID],
                  parent.id != item.id,
                  parent.parentID == nil,
                  parent.group == item.group else {
                throw TaskStoreError.invalidHierarchy
            }
        }
    }
}
