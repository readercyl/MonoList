import AppKit
import SwiftUI

struct SettingsView: View {
    private static let controlWidth: CGFloat = 180
    private static let controlHeight: CGFloat = 26

    @ObservedObject var settings: AppSettings
    @ObservedObject var taskStore: TaskStore
    @ObservedObject var focusStore: FocusStore
    @ObservedObject var reminderScheduler: ReminderScheduler
    @ObservedObject var loginItemController: LoginItemController
    @ObservedObject var updater: AppUpdater
    let onInstallUpdate: (AppUpdate) -> Void
    let onTestReminder: () -> Void

    @State private var errorMessage: String?
    @State private var currentDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            softwareInformation
            SettingsCard(title: "轻提醒", systemImage: "bell") {
                reminderSettings
            }
            SettingsCard(title: "启动", systemImage: "power") {
                startupSettings
            }
        }
        .padding(16)
        .frame(width: WindowCoordinator.settingsWindowWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onReceive(
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
        ) { date in
            currentDate = date
        }
    }

    private var softwareInformation: some View {
        HStack(alignment: .top, spacing: 14) {
            MonoListLogoView(size: 58)
            VStack(alignment: .leading, spacing: 0) {
                Text("MonoList")
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                HStack(spacing: 7) {
                    Text("版本 \(appVersion)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(height: 24)
                    Button(updater.isChecking ? "检测中…" : "检测新版本") {
                        Task {
                            await updater.check(manual: true, settings: settings)
                        }
                    }
                    .buttonStyle(InlineUpdateButtonStyle())
                    .disabled(updater.isChecking)

                    if !updater.statusText.isEmpty {
                        Text(updater.statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(updateStatusColor)
                            .lineLimit(1)
                    }
                    if let update = updater.availableUpdate {
                        Button(updater.isInstalling ? "升级中…" : "升级") {
                            onInstallUpdate(update)
                        }
                        .buttonStyle(InlineUpdateButtonStyle())
                        .disabled(updater.isInstalling)
                    }
                }
            }
            .frame(height: 58)
            Spacer(minLength: 0)
        }
        .frame(height: 58)
    }

    private var reminderSettings: some View {
        VStack(spacing: 8) {
            settingsRow("启用轻提醒") {
                Toggle(
                    "",
                    isOn: binding(
                        get: { settings.reminderEnabled },
                        update: { $0.reminderEnabled = $1 }
                    )
                )
                .labelsHidden()
                .toggleStyle(SettingsSwitchStyle())
            }
            Text("设置今日专注后，轻提醒只提示当前任务。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            settingsRow("提醒声音") {
                SettingsPopupButton(
                    items: ["关闭"] + Self.systemSoundNames,
                    selectedTitle: settings.reminderSoundEnabled
                        ? settings.reminderSoundName
                        : "关闭"
                ) { title in
                    updateSettings {
                        $0.reminderSoundEnabled = title != "关闭"
                        if title != "关闭" { $0.reminderSoundName = title }
                    }
                    if title != "关闭" {
                        (NSSound(named: NSSound.Name(title)) ??
                            NSSound(named: NSSound.Name("Glass")))?.play()
                    }
                }
                .frame(width: Self.controlWidth, height: Self.controlHeight)
            }
            Divider().opacity(0.4)
            settingsRow("提醒时段") {
                HStack(spacing: 6) {
                    SettingsPopupButton(
                        items: Self.startTimeItems.map(Self.timeTitle),
                        selectedTitle: Self.timeTitle(
                            settings.reminderStartMinuteOfDay
                        ),
                        maxVisibleItems: 8
                    ) { title in
                        guard let minute = Self.minuteOfDay(for: title) else {
                            return
                        }
                        updateSettings {
                            $0.reminderStartMinuteOfDay = minute
                        }
                    }
                    .frame(width: 78, height: Self.controlHeight)
                    Text("至")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    SettingsPopupButton(
                        items: Self.endTimeItems.map(Self.timeTitle),
                        selectedTitle: Self.timeTitle(
                            settings.reminderEndMinuteOfDay
                        ),
                        maxVisibleItems: 8
                    ) { title in
                        guard let minute = Self.minuteOfDay(for: title) else {
                            return
                        }
                        updateSettings {
                            $0.reminderEndMinuteOfDay = minute
                        }
                    }
                    .frame(width: 78, height: Self.controlHeight)
                }
                .frame(width: Self.controlWidth, height: Self.controlHeight)
            }
            settingsRow("提醒间隔") {
                SettingsPopupButton(
                    items: [30, 60, 90, 120].map { "\($0) 分钟" },
                    selectedTitle: "\(settings.reminderIntervalMinutes) 分钟"
                ) { title in
                    guard let interval = Int(
                        title.split(separator: " ").first ?? ""
                    ) else {
                        return
                    }
                    updateSettings {
                        $0.reminderIntervalMinutes = interval
                    }
                }
                .frame(width: Self.controlWidth, height: Self.controlHeight)
            }
            settingsRow("下次提醒") {
                Text(nextReminderText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(nextReminderColor)
                    .lineLimit(1)
                    .frame(
                        width: Self.controlWidth,
                        height: Self.controlHeight,
                        alignment: .center
                    )
                    .modifier(SettingValueBackground())
            }
            settingsRow("提醒位置") {
                SettingsPopupButton(
                    items: ReminderPosition.supportedCases.map(\.title),
                    selectedTitle: settings.reminderPosition.title
                ) { title in
                    guard let position = ReminderPosition.supportedCases.first(
                        where: { $0.title == title }
                    ) else {
                        return
                    }
                    updateSettings {
                        $0.reminderPosition = position
                    }
                }
                .frame(width: Self.controlWidth, height: Self.controlHeight)
            }
            settingsRow("提醒测试") {
                Button("立即测试", action: onTestReminder)
                    .buttonStyle(FixedQuietButtonStyle(width: 180))
            }
        }
    }

    private static let systemSoundNames = [
        "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
    ].filter { NSSound(named: NSSound.Name($0)) != nil }

    private var startupSettings: some View {
        VStack(spacing: 8) {
            settingsRow("自动更新") {
                Toggle(
                    "",
                    isOn: binding(
                        get: { settings.automaticUpdatesEnabled },
                        update: { $0.automaticUpdatesEnabled = $1 }
                    )
                )
                .labelsHidden()
                .toggleStyle(SettingsSwitchStyle())
            }
            settingsRow("开机后自动启动") {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { loginItemController.status == .enabled },
                        set: { enabled in
                            do {
                                try loginItemController.setEnabled(enabled)
                                try settings.update { $0.launchAtLogin = enabled }
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(SettingsSwitchStyle())
            }
        }
    }

    private func settingsRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .medium))
            Spacer(minLength: 16)
            content()
                .frame(width: Self.controlWidth, alignment: .trailing)
        }
        .frame(minHeight: 34)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.3.0"
    }

    private var nextReminderText: String {
        Self.nextReminderStatusText(
            enabled: settings.reminderEnabled,
            hasActiveFocus: focusStore.isActive(at: currentDate),
            lightReminderTaskCount: lightReminderTasks.count,
            nextReminderDate: reminderScheduler.nextReminderDate,
            relativeTo: currentDate
        )
    }

    private var nextReminderColor: Color {
        if settings.reminderEnabled && !lightReminderTasks.isEmpty {
            return .primary
        }
        return .secondary
    }

    private var lightReminderTasks: [TaskItem] {
        ReminderScheduler.lightReminderTasks(
            in: taskStore.tasks,
            focusTaskIDs: focusStore.isActive(at: currentDate)
                ? focusStore.taskIDs(at: currentDate)
                : nil
        )
    }

    private var updateStatusColor: Color {
        if updater.availableUpdate != nil {
            return .green
        }
        if updater.statusText.contains("失败") ||
            updater.statusText.contains("无法") {
            return .red
        }
        return .secondary
    }

    private func binding<Value>(
        get: @escaping () -> Value,
        update: @escaping (inout SettingsValues, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: get,
            set: { value in
                do {
                    try settings.update { update(&$0, value) }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        )
    }

    private func updateSettings(_ mutation: (inout SettingsValues) -> Void) {
        do {
            try settings.update(mutation)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static let startTimeItems = stride(from: 0, to: 24 * 60, by: 30).map { $0 }
    static let endTimeItems = stride(from: 30, through: 24 * 60, by: 30).map { $0 }

    static func timeTitle(_ minuteOfDay: Int) -> String {
        let hour = minuteOfDay / 60
        let minute = minuteOfDay % 60
        return String(format: "%02d:%02d", hour, minute)
    }

    static func minuteOfDay(for title: String) -> Int? {
        let parts = title.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }
        return hour * 60 + minute
    }

    static func nextReminderTitle(
        for date: Date,
        relativeTo referenceDate: Date,
        calendar: Calendar = .current
    ) -> String {
        let time = date.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
        )
        if calendar.isDate(date, inSameDayAs: referenceDate) {
            return "今天 \(time)"
        }
        if let tomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: referenceDate)
        ), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "明天 \(time)"
        }
        let day = date.formatted(.dateTime.month().day())
        return "\(day) \(time)"
    }

    static func nextReminderStatusText(
        enabled: Bool,
        hasActiveFocus: Bool,
        lightReminderTaskCount: Int,
        nextReminderDate: Date?,
        relativeTo referenceDate: Date,
        calendar: Calendar = .current
    ) -> String {
        guard enabled else { return "未启用" }
        if hasActiveFocus && lightReminderTaskCount == 0 {
            return "今日专注已完成"
        }
        guard lightReminderTaskCount > 0 else { return "暂无待办" }
        guard let nextReminderDate else { return "等待调度" }
        return nextReminderTitle(
            for: nextReminderDate,
            relativeTo: referenceDate,
            calendar: calendar
        )
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct InlineUpdateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.10 : 0.055),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}

private struct FixedQuietButtonStyle: ButtonStyle {
    let width: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .regular))
            .frame(width: width, height: 26)
            .modifier(SettingValueBackground(isPressed: configuration.isPressed))
    }
}

private struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    configuration.isOn
                        ? Color.accentColor
                        : Color.primary.opacity(0.16)
                )
                .frame(width: 54, height: 28)
                .overlay {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 24, height: 24)
                        .shadow(
                            color: Color.black.opacity(0.18),
                            radius: 1.5,
                            x: 0,
                            y: 1
                        )
                        .offset(x: configuration.isOn ? 13 : -13)
                }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: configuration.isOn)
    }
}

private struct SettingsPopupButton: View {
    let items: [String]
    let selectedTitle: String
    var maxVisibleItems: Int? = nil
    let onSelect: (String) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack {
                Text(selectedTitle)
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
            .frame(height: 26)
            .modifier(SettingValueBackground())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(items, id: \.self) { item in
                        Button {
                            onSelect(item)
                            isPresented = false
                        } label: {
                            Text(item)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .frame(height: Self.menuRowHeight)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 180, height: menuHeight)
        }
    }

    private var menuHeight: CGFloat {
        let visibleCount = min(items.count, maxVisibleItems ?? items.count)
        return CGFloat(visibleCount) * Self.menuRowHeight + 8
    }

    private static let menuRowHeight: CGFloat = 28
}

private struct SettingValueBackground: ViewModifier {
    var isPressed = false

    func body(content: Content) -> some View {
        content
            .background(
                Color.primary.opacity(isPressed ? 0.10 : 0.045),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }
}
