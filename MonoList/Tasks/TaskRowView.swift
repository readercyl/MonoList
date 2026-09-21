import SwiftUI

struct TaskRowView: View {
    let item: TaskItem
    let onSave: (String) -> Void
    let onComplete: (String) -> Bool
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onInsertAfter: () -> Void
    let onUpdateReminder: (TaskReminder?) -> Void
    let isSelected: Bool
    let onSelect: () -> Void
    let onEditingChanged: (Bool) -> Void
    let indentationLevel: Int
    let hasSubtasks: Bool
    let isExpanded: Bool
    let onToggleSubtasks: () -> Void
    let onAddSubtask: (() -> Void)?
    let canAddSubtask: Bool
    let onIndent: (() -> Bool)?
    let onOutdent: (() -> Bool)?
    let subtaskProgressText: String?
    let priorityRank: Int?

    @State private var text: String
    @State private var originalText: String
    @State private var isEditingMode = false
    @State private var isHovered = false
    @State private var isEditorFocused = false
    @State private var isReminderPopoverPresented = false
    @State private var isCompleting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        item: TaskItem,
        onSave: @escaping (String) -> Void,
        onComplete: @escaping (String) -> Bool,
        onDelete: @escaping () -> Void,
        onMoveUp: @escaping () -> Void,
        onMoveDown: @escaping () -> Void,
        onInsertAfter: @escaping () -> Void,
        onUpdateReminder: @escaping (TaskReminder?) -> Void,
        isSelected: Bool,
        onSelect: @escaping () -> Void,
        onEditingChanged: @escaping (Bool) -> Void,
        indentationLevel: Int = 0,
        hasSubtasks: Bool = false,
        isExpanded: Bool = true,
        onToggleSubtasks: @escaping () -> Void = {},
        onAddSubtask: (() -> Void)? = nil,
        canAddSubtask: Bool = false,
        onIndent: (() -> Bool)? = nil,
        onOutdent: (() -> Bool)? = nil,
        subtaskProgressText: String? = nil,
        priorityRank: Int? = nil
    ) {
        self.item = item
        self.onSave = onSave
        self.onComplete = onComplete
        self.onDelete = onDelete
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        self.onInsertAfter = onInsertAfter
        self.onUpdateReminder = onUpdateReminder
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onEditingChanged = onEditingChanged
        self.indentationLevel = indentationLevel
        self.hasSubtasks = hasSubtasks
        self.isExpanded = isExpanded
        self.onToggleSubtasks = onToggleSubtasks
        self.onAddSubtask = onAddSubtask
        self.canAddSubtask = canAddSubtask
        self.onIndent = onIndent
        self.onOutdent = onOutdent
        self.subtaskProgressText = subtaskProgressText
        self.priorityRank = priorityRank
        _text = State(initialValue: item.text)
        _originalText = State(initialValue: item.text)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            hierarchyControl

            TaskCompletionButton(
                symbolSize: 18,
                frameSize: 28,
                isCompleting: isCompleting,
                action: beginCompletion
            )

            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if isEditingMode {
                        TaskTextEditor(
                            text: $text,
                            isFocused: $isEditorFocused,
                            fontSize: textFontSize,
                            fontWeight: editorFontWeight,
                            onSubmit: {
                                finishEditing()
                                onInsertAfter()
                            },
                            onIndent: onIndent,
                            onOutdent: onOutdent
                        )
                            .onAppear {
                                DispatchQueue.main.async {
                                    isEditorFocused = true
                                }
                            }
                    } else {
                        Text(text)
                            .font(.system(size: textFontSize, weight: textFontWeight))
                            .strikethrough(isCompleting)
                            .foregroundStyle(isCompleting ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentShape(Rectangle())
                            .highPriorityGesture(
                                TapGesture(count: 2).onEnded {
                                    beginEditing()
                                }
                            )
                    }
                }
                if !isEditingMode {
                    subtaskProgressLine
                    reminderStatusLine
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isCompleting ? 0.66 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.16),
                value: reminderTitle
            )

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .opacity(isHovered || isSelected ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.16),
                        value: isHovered || isSelected
                    )
            }
            .buttonStyle(.plain)
            .help("删除")

            if canAddSubtask, let onAddSubtask {
                Button(action: onAddSubtask) {
                    Image(systemName: "plus")
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .opacity(isHovered || isSelected ? 1 : 0)
                        .animation(
                            reduceMotion ? nil : .easeOut(duration: 0.16),
                            value: isHovered || isSelected
                        )
                }
                .buttonStyle(.plain)
                .help("添加子任务")
            }
        }
        .padding(.leading, CGFloat(indentationLevel) * 21 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(
            isSelected && !isEditingMode ? Color.primary.opacity(0.055) : .clear,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isSelected
        )
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                // Let NSTextView keep the click when this row is editing so
                // the user can place or extend the insertion point.
                guard !isEditingMode else { return }
                onSelect()
            }
        )
        .onHover { isHovered = $0 }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.16),
            value: isCompleting
        )
        .onChange(of: isEditorFocused) { oldValue, newValue in
            if oldValue && !newValue && isEditingMode {
                finishEditing()
            }
        }
        .onChange(of: isSelected) { _, newValue in
            if !newValue && isEditingMode {
                isEditorFocused = false
            }
        }
        .onDisappear {
            if isEditingMode {
                finishEditing()
            }
        }
        .contextMenu {
            Button("设置提醒…") {
                DispatchQueue.main.async {
                    isReminderPopoverPresented = true
                }
            }
            if item.reminder != nil {
                Button("清除提醒") {
                    onUpdateReminder(nil)
                }
            }
            Divider()
            Button("上移", action: onMoveUp)
            Button("下移", action: onMoveDown)
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
        .popover(isPresented: $isReminderPopoverPresented, arrowEdge: .trailing) {
            TaskReminderEditor(
                reminder: item.reminder,
                onSave: { reminder in
                    onUpdateReminder(reminder)
                    isReminderPopoverPresented = false
                },
                onClear: {
                    onUpdateReminder(nil)
                    isReminderPopoverPresented = false
                }
            )
        }
    }

    private var hierarchyControl: some View {
        Group {
            if hasSubtasks {
                Button(action: onToggleSubtasks) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 20, height: 28)
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "隐藏子任务" : "展开子任务")
                .accessibilityLabel(isExpanded ? "隐藏子任务" : "展开子任务")
            } else {
                Color.clear.frame(
                    width: indentationLevel == 0 ? 0 : 20,
                    height: 28
                )
            }
        }
    }

    @ViewBuilder
    private var subtaskProgressLine: some View {
        if let subtaskProgressText {
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                    .font(.system(size: 10, weight: .medium))
                Text(subtaskProgressText)
                    .font(.system(size: 11, weight: .regular))
            }
            .foregroundStyle(.secondary)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var reminderStatusLine: some View {
        if let title = reminderTitle {
            HStack(spacing: 4) {
                Image(systemName: "bell")
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11, weight: .regular))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)
        }
    }

    private var reminderTitle: String? {
        guard let reminder = item.reminder else { return nil }
        switch reminder.kind {
        case .once:
            guard let date = reminder.date else { return nil }
            if Calendar.current.isDateInToday(date) {
                return "今天 \(Self.timeTitle(for: date))"
            }
            return "\(date.formatted(.dateTime.month().day())) \(Self.timeTitle(for: date))"
        case .daily:
            return "每天 \(Self.timeTitle(minuteOfDay: reminder.minuteOfDay))"
        }
    }

    private var textFontSize: CGFloat {
        switch priorityRank {
        case 0: return 18
        case 1: return 16
        case 2: return 14
        default: return 13
        }
    }

    private var textFontWeight: Font.Weight {
        switch priorityRank {
        case 0: return .semibold
        case 1: return .medium
        default: return .regular
        }
    }

    private var editorFontWeight: NSFont.Weight {
        switch priorityRank {
        case 0: return .semibold
        case 1: return .medium
        default: return .regular
        }
    }

    private func beginEditing() {
        originalText = text
        onSelect()
        isEditingMode = true
        onEditingChanged(true)
    }

    private func beginCompletion() {
        guard !isCompleting else { return }
        if isEditingMode {
            finishEditing()
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            isCompleting = true
        }
        let delay = reduceMotion ? 0 : 0.24
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard !onComplete(text) else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                isCompleting = false
            }
        }
    }

    private func finishEditing() {
        saveIfNeeded()
        isEditorFocused = false
        isEditingMode = false
        onEditingChanged(false)
    }

    private func saveIfNeeded() {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            text = originalText
            return
        }
        guard text != originalText else { return }
        onSave(text)
        originalText = text
    }

    private static func timeTitle(for date: Date) -> String {
        date.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        )
    }

    private static func timeTitle(minuteOfDay: Int) -> String {
        let hour = minuteOfDay / 60
        let minute = minuteOfDay % 60
        return String(format: "%02d:%02d", hour, minute)
    }
}

struct TaskCompletionButton: View {
    let symbolSize: CGFloat
    let frameSize: CGFloat
    let isCompleting: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "circle")
                    .opacity(isCompleting ? 0 : 1)
                    .scaleEffect(isCompleting ? 0.82 : 1)
                Image(systemName: "checkmark.circle.fill")
                    .opacity(isCompleting ? 1 : 0)
                    .scaleEffect(isCompleting ? 1 : 0.82)
            }
            .font(.system(size: symbolSize, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(width: frameSize, height: frameSize)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.16),
                value: isCompleting
            )
        }
        .buttonStyle(.plain)
        .disabled(isCompleting)
        .help(isCompleting ? "已完成" : "标记为完成")
        .accessibilityLabel(isCompleting ? "已完成" : "标记为完成")
    }
}

private enum TaskReminderEditMode: String, CaseIterable, Identifiable {
    case countdown = "倒计时"
    case date = "日期"
    case daily = "每天"

    var id: String { rawValue }
}

private struct TaskReminderEditor: View {
    let reminder: TaskReminder?
    let onSave: (TaskReminder) -> Void
    let onClear: () -> Void

    @State private var mode: TaskReminderEditMode
    @State private var hour: Int
    @State private var minute: Int
    @State private var dayOffset: Int
    @State private var countdownMinutes = 10

    init(
        reminder: TaskReminder?,
        onSave: @escaping (TaskReminder) -> Void,
        onClear: @escaping () -> Void
    ) {
        self.reminder = reminder
        self.onSave = onSave
        self.onClear = onClear
        let initialMode: TaskReminderEditMode
        let initialMinuteOfDay: Int
        switch reminder?.kind {
        case .daily:
            initialMode = .daily
            initialMinuteOfDay = reminder?.minuteOfDay ?? Self.nearestUpcomingMinute()
        case .once:
            initialMode = .date
            initialMinuteOfDay = reminder?.date.map(Self.minuteOfDay) ??
                Self.nearestUpcomingMinute()
        case nil:
            initialMode = .countdown
            initialMinuteOfDay = Self.nearestUpcomingMinute()
        }
        _mode = State(initialValue: initialMode)
        _hour = State(initialValue: initialMinuteOfDay / 60)
        _minute = State(initialValue: initialMinuteOfDay % 60)
        let reminderDay = reminder?.date ?? Date()
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: reminderDay)
        ).day ?? 0
        _dayOffset = State(initialValue: min(max(days, 0), 7))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提醒我")
                .font(.system(size: 13, weight: .semibold))

            Picker("", selection: $mode) {
                ForEach(TaskReminderEditMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .countdown {
                ReminderTimeDropdown(
                    title: "\(countdownMinutes) 分钟后",
                    values: stride(from: 10, through: 120, by: 10).map { $0 },
                    selectedValue: countdownMinutes,
                    titleForValue: { "\($0) 分钟后" },
                    onSelect: { countdownMinutes = $0 }
                )
            } else {
                if mode == .date {
                    ReminderTimeDropdown(
                        title: Self.dayTitle(offset: dayOffset),
                        values: Array(0...7),
                        selectedValue: dayOffset,
                        titleForValue: Self.dayTitle(offset:),
                        onSelect: { dayOffset = $0 }
                    )
                }
                HStack(spacing: 8) {
                ReminderTimeDropdown(
                    title: String(format: "%02d 时", hour),
                    values: Array(0...23),
                    selectedValue: hour,
                    titleForValue: { String(format: "%02d 时", $0) },
                    onSelect: { hour = $0 }
                )
                ReminderTimeDropdown(
                    title: String(format: "%02d 分", minute),
                    values: stride(from: 0, through: 50, by: 10).map { $0 },
                    selectedValue: minute,
                    titleForValue: { String(format: "%02d 分", $0) },
                    onSelect: { minute = $0 }
                )
                }
            }

            HStack {
                Button("清除提醒", action: onClear)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .disabled(reminder == nil)
                Spacer()
                Button("保存") {
                    onSave(makeReminder())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(saveDisabled ? .secondary : .primary)
                .disabled(saveDisabled)
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    private var saveDisabled: Bool {
        mode == .date && scheduledReminderDate <= Date()
    }

    private var scheduledReminderDate: Date {
        let day = Calendar.current.date(
            byAdding: .day,
            value: dayOffset,
            to: Date()
        ) ?? Date()
        return TaskReminder.once(on: day, minuteOfDay: minuteOfDay)?.date ?? Date()
    }

    private var minuteOfDay: Int {
        hour * 60 + minute
    }

    private func makeReminder() -> TaskReminder {
        switch mode {
        case .countdown:
            return .countdown(minutes: countdownMinutes)
        case .date:
            return .once(at: scheduledReminderDate)
        case .daily:
            return .daily(
                minuteOfDay: minuteOfDay,
                id: reminder?.recurrenceID ?? UUID(),
                lastTriggeredAt: reminder?.lastTriggeredAt
            )
        }
    }

    private static func dayTitle(offset: Int) -> String {
        if offset == 0 { return "今天" }
        if offset == 1 { return "明天" }
        guard let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else {
            return "未来第 \(offset) 天"
        }
        return date.formatted(.dateTime.month().day().weekday(.abbreviated))
    }

    private static func nearestUpcomingMinute(now: Date = Date()) -> Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let current = (components.hour ?? 9) * 60 + (components.minute ?? 0)
        let rounded = ((current + 9) / 10) * 10
        return min(rounded, 23 * 60 + 50)
    }

    private static func minuteOfDay(for date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private static func timeTitle(minuteOfDay: Int) -> String {
        let hour = minuteOfDay / 60
        let minute = minuteOfDay % 60
        return String(format: "%02d:%02d", hour, minute)
    }
}

private struct ReminderTimeDropdown: View {
    let title: String
    let values: [Int]
    let selectedValue: Int
    let titleForValue: (Int) -> String
    let onSelect: (Int) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                HStack {
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 28)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(values, id: \.self) { value in
                        Button {
                            onSelect(value)
                            isPresented = false
                        } label: {
                            Text(titleForValue(value))
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .frame(height: Self.rowHeight)
                                .background(
                                    value == selectedValue ?
                                        Color.primary.opacity(0.055) : .clear
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 86, height: menuHeight)
        }
    }

    private var menuHeight: CGFloat {
        CGFloat(min(values.count, Self.maxVisibleItems)) * Self.rowHeight + 8
    }

    private static let maxVisibleItems = 8
    private static let rowHeight: CGFloat = 28
}
