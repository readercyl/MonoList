import Foundation

enum TaskStatus: String, Codable {
    case pending
    case history
}

// Kept only so older tasks.json files remain readable. The current product
// presents one unified pending-task order and no longer exposes this field.
enum TaskGroup: String, Codable, CaseIterable {
    case shortTerm
    case longTerm
}

enum TaskReminderKind: String, Codable {
    case once
    case daily
}

struct TaskReminder: Codable, Equatable {
    var kind: TaskReminderKind
    var date: Date?
    var minuteOfDay: Int
    var recurrenceID: UUID?
    var lastTriggeredAt: Date?

    static func once(at date: Date) -> TaskReminder {
        TaskReminder(
            kind: .once,
            date: date,
            minuteOfDay: 0,
            recurrenceID: nil,
            lastTriggeredAt: nil
        )
    }

    static func countdown(minutes: Int, from date: Date = Date()) -> TaskReminder {
        .once(at: date.addingTimeInterval(TimeInterval(minutes * 60)))
    }

    static func once(
        on day: Date,
        minuteOfDay: Int,
        calendar: Calendar = .current
    ) -> TaskReminder? {
        guard (0..<24 * 60).contains(minuteOfDay) else { return nil }
        let startOfDay = calendar.startOfDay(for: day)
        guard let date = calendar.date(
            byAdding: .minute,
            value: minuteOfDay,
            to: startOfDay
        ) else { return nil }
        return .once(at: date)
    }

    static func daily(
        minuteOfDay: Int,
        id: UUID = UUID(),
        lastTriggeredAt: Date? = nil
    ) -> TaskReminder {
        TaskReminder(
            kind: .daily,
            date: nil,
            minuteOfDay: minuteOfDay,
            recurrenceID: id,
            lastTriggeredAt: lastTriggeredAt
        )
    }
}

struct TaskItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var status: TaskStatus
    var order: Int
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var reminder: TaskReminder? = nil
    var group: TaskGroup = .shortTerm
    var parentID: UUID? = nil

    private enum CodingKeys: String, CodingKey {
        case id, text, status, order, createdAt, updatedAt, completedAt, reminder, group,
             parentID
    }

    init(
        id: UUID,
        text: String,
        status: TaskStatus,
        order: Int,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date?,
        reminder: TaskReminder? = nil,
        group: TaskGroup = .shortTerm,
        parentID: UUID? = nil
    ) {
        self.id = id
        self.text = text
        self.status = status
        self.order = order
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.reminder = reminder
        self.group = group
        self.parentID = parentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        status = try container.decode(TaskStatus.self, forKey: .status)
        order = try container.decode(Int.self, forKey: .order)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        reminder = try container.decodeIfPresent(TaskReminder.self, forKey: .reminder)
        group = try container.decodeIfPresent(TaskGroup.self, forKey: .group) ?? .shortTerm
        parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
    }
}

struct TaskDatabase: Codable, Equatable {
    static let legacySchemaVersion = 1
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    var tasks: [TaskItem]

    init(tasks: [TaskItem]) {
        schemaVersion = Self.currentSchemaVersion
        self.tasks = tasks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.legacySchemaVersion ||
            schemaVersion == Self.currentSchemaVersion else {
            throw TaskDatabaseError.invalidSchemaVersion
        }
        tasks = try container.decode([TaskItem].self, forKey: .tasks)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, tasks
    }
}

enum TaskDatabaseError: Error {
    case invalidSchemaVersion
}
