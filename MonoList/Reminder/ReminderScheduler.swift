import Foundation

@MainActor
final class ReminderScheduler: ObservableObject {
    private(set) var deadline: TimeInterval?
    @Published private(set) var nextReminderDate: Date?

    private let now: () -> TimeInterval
    private let wallClock: () -> Date
    private let calendar: Calendar
    private let onDue: () -> Void
    private let onDedicatedReminderDue: (UUID) -> Void
    private var enabled = false
    private var interval: TimeInterval = 60 * 60
    private var startMinuteOfDay = 9 * 60
    private var endMinuteOfDay = 22 * 60
    private var pendingCount = 0
    private var pendingTasks: [TaskItem] = []
    private var dispatchedDedicatedReminderKeys = Set<String>()
    private var pollingTimer: Timer?

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wallClock: @escaping () -> Date = { Date() },
        calendar: Calendar = .current,
        onDue: @escaping () -> Void,
        onDedicatedReminderDue: @escaping (UUID) -> Void = { _ in }
    ) {
        self.now = now
        self.wallClock = wallClock
        self.calendar = calendar
        self.onDue = onDue
        self.onDedicatedReminderDue = onDedicatedReminderDue
    }

    func configure(
        enabled: Bool,
        intervalMinutes: Int,
        startMinuteOfDay: Int = 9 * 60,
        endMinuteOfDay: Int = 22 * 60,
        pendingCount: Int
    ) {
        configureGlobalSchedule(
            enabled: enabled,
            intervalMinutes: intervalMinutes,
            startMinuteOfDay: startMinuteOfDay,
            endMinuteOfDay: endMinuteOfDay,
            pendingCount: pendingCount
        )
    }

    func configure(
        enabled: Bool,
        intervalMinutes: Int,
        startMinuteOfDay: Int = 9 * 60,
        endMinuteOfDay: Int = 22 * 60,
        pendingTasks: [TaskItem],
        lightReminderTasks: [TaskItem]? = nil
    ) {
        self.pendingTasks = pendingTasks
        let reminderTasks = lightReminderTasks ?? pendingTasks
        configureGlobalSchedule(
            enabled: enabled,
            intervalMinutes: intervalMinutes,
            startMinuteOfDay: startMinuteOfDay,
            endMinuteOfDay: endMinuteOfDay,
            pendingCount: reminderTasks.count
        )
    }

    private func configureGlobalSchedule(
        enabled: Bool,
        intervalMinutes: Int,
        startMinuteOfDay: Int,
        endMinuteOfDay: Int,
        pendingCount: Int
    ) {
        let changed = self.enabled != enabled ||
            self.interval != TimeInterval(intervalMinutes * 60) ||
            self.startMinuteOfDay != startMinuteOfDay ||
            self.endMinuteOfDay != endMinuteOfDay
        self.enabled = enabled
        interval = TimeInterval(intervalMinutes * 60)
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
        self.pendingCount = pendingCount

        if !enabled || pendingCount == 0 {
            deadline = nil
            nextReminderDate = nil
        } else if changed || deadline == nil {
            restart()
        }
    }

    func pendingCountChanged(from oldCount: Int, to newCount: Int) {
        pendingCount = newCount
        guard enabled else {
            deadline = nil
            nextReminderDate = nil
            return
        }
        if newCount == 0 {
            deadline = nil
            nextReminderDate = nil
        } else if oldCount == 0 {
            restart()
        }
    }

    func wake(pendingCount: Int) {
        self.pendingCount = pendingCount
        if enabled && pendingCount > 0 {
            restart()
        } else {
            deadline = nil
            nextReminderDate = nil
        }
    }

    func meaningfulInteraction(pendingCount: Int) {
        self.pendingCount = pendingCount
        if enabled && pendingCount > 0 {
            restart()
        } else {
            deadline = nil
            nextReminderDate = nil
        }
    }

    func evaluate(interfaceBusy: Bool) {
        let evaluationDate = wallClock()
        if !interfaceBusy,
           let dedicatedTask = Self.dueDedicatedReminderTasks(
               in: pendingTasks,
               at: evaluationDate,
               calendar: calendar
           ).first(where: { task in
               let key = Self.dedicatedReminderDispatchKey(
                   for: task,
                   at: evaluationDate,
                   calendar: calendar
               )
               return !dispatchedDedicatedReminderKeys.contains(key)
           }) {
            let key = Self.dedicatedReminderDispatchKey(
                for: dedicatedTask,
                at: evaluationDate,
                calendar: calendar
            )
            dispatchedDedicatedReminderKeys.insert(key)
            onDedicatedReminderDue(dedicatedTask.id)
            if enabled && pendingCount > 0 {
                restart()
            }
            return
        }

        guard let deadline, now() >= deadline else {
            return
        }
        guard enabled, pendingCount > 0 else {
            self.deadline = nil
            nextReminderDate = nil
            return
        }
        if interfaceBusy {
            restart()
        } else {
            self.deadline = nil
            nextReminderDate = nil
            onDue()
        }
    }

    func reminderClosed(pendingCount: Int) {
        self.pendingCount = pendingCount
        if enabled && pendingCount > 0 {
            restart()
        } else {
            deadline = nil
            nextReminderDate = nil
        }
    }

    func startPolling(interfaceBusy: @escaping () -> Bool) {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.evaluate(interfaceBusy: interfaceBusy())
            }
        }
    }

    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        deadline = nil
        nextReminderDate = nil
    }

    private func restart() {
        let scheduledDate = Self.nextReminderDate(
            after: wallClock(),
            intervalMinutes: Int(interval / 60),
            startMinuteOfDay: startMinuteOfDay,
            endMinuteOfDay: endMinuteOfDay,
            calendar: calendar
        )
        let delay = max(0, scheduledDate.timeIntervalSince(wallClock()))
        deadline = now() + delay
        nextReminderDate = scheduledDate
    }

    static func nextReminderDate(
        after date: Date,
        intervalMinutes: Int,
        startMinuteOfDay: Int,
        endMinuteOfDay: Int,
        calendar: Calendar = .current
    ) -> Date {
        let candidate = date.addingTimeInterval(TimeInterval(intervalMinutes * 60))
        let candidateStart = boundaryDate(
            matching: startMinuteOfDay,
            on: candidate,
            calendar: calendar
        )
        let candidateEnd = boundaryDate(
            matching: endMinuteOfDay,
            on: candidate,
            calendar: calendar
        )
        if candidate >= candidateStart && candidate <= candidateEnd {
            return candidate
        }
        if candidate < candidateStart {
            return candidateStart
        }
        let tomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: candidate
        ) ?? candidate
        return boundaryDate(
            matching: startMinuteOfDay,
            on: tomorrow,
            calendar: calendar
        )
    }

    static func dueDedicatedReminderTask(
        in tasks: [TaskItem],
        at date: Date,
        calendar: Calendar = .current
    ) -> TaskItem? {
        dueDedicatedReminderTasks(in: tasks, at: date, calendar: calendar).first
    }

    static func dueDedicatedReminderTasks(
        in tasks: [TaskItem],
        at date: Date,
        calendar: Calendar = .current
    ) -> [TaskItem] {
        tasks
            .filter { $0.status == .pending }
            .compactMap { task -> (TaskItem, Date)? in
                guard let reminderDate = dedicatedReminderDate(
                    for: task,
                    on: date,
                    calendar: calendar
                ), reminderDate <= date else {
                    return nil
                }
                return (task, reminderDate)
            }
            .sorted {
                if $0.1 != $1.1 {
                    return $0.1 < $1.1
                }
                return $0.0.order < $1.0.order
            }
            .map(\.0)
    }

    static func lightReminderTasks(in tasks: [TaskItem]) -> [TaskItem] {
        Array(
            tasks
                .filter { $0.status == .pending && $0.reminder == nil }
                .sorted(by: { lhs, rhs in
                    if lhs.order != rhs.order {
                        return lhs.order < rhs.order
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                })
                .prefix(3)
        )
    }

    static func dedicatedReminderDate(
        for task: TaskItem,
        on date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let reminder = task.reminder else { return nil }
        switch reminder.kind {
        case .once:
            return reminder.date
        case .daily:
            guard (0..<24 * 60).contains(reminder.minuteOfDay) else {
                return nil
            }
            if let lastTriggeredAt = reminder.lastTriggeredAt,
               calendar.isDate(lastTriggeredAt, inSameDayAs: date) {
                return nil
            }
            return boundaryDate(
                matching: reminder.minuteOfDay,
                on: date,
                calendar: calendar
            )
        }
    }

    private static func dedicatedReminderDispatchKey(
        for task: TaskItem,
        at date: Date,
        calendar: Calendar
    ) -> String {
        guard let reminder = task.reminder else {
            return task.id.uuidString
        }
        switch reminder.kind {
        case .once:
            return "\(task.id.uuidString)-once-\(reminder.date?.timeIntervalSince1970 ?? 0)"
        case .daily:
            let day = calendar.startOfDay(for: date).timeIntervalSince1970
            return "\(task.id.uuidString)-daily-\(day)"
        }
    }

    private static func boundaryDate(
        matching minuteOfDay: Int,
        on date: Date,
        calendar: Calendar
    ) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        return startOfDay.addingTimeInterval(TimeInterval(minuteOfDay * 60))
    }
}
