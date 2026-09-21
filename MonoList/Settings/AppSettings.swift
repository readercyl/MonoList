import Combine
import Foundation

enum AppSettingsError: LocalizedError {
    case recoveryRequired
    case invalidReminderInterval
    case invalidReminderTimeRange

    var errorDescription: String? {
        switch self {
        case .recoveryRequired:
            return "设置数据读取失败，请重试"
        case .invalidReminderInterval:
            return "提醒间隔无效"
        case .invalidReminderTimeRange:
            return "提醒时段无效"
        }
    }
}

enum ReminderPosition: String, Codable, CaseIterable, Identifiable {
    case center
    case topCenter
    case belowMenuBar
    case topRight

    var id: String { rawValue }

    static let supportedCases: [ReminderPosition] = [.topCenter, .topRight]

    var supportedValue: ReminderPosition {
        switch self {
        case .topCenter, .topRight:
            return self
        case .center, .belowMenuBar:
            return .topCenter
        }
    }

    var title: String {
        switch self {
        case .center:
            return "屏幕中间"
        case .topCenter:
            return "顶部居中"
        case .belowMenuBar:
            return "菜单栏下方"
        case .topRight:
            return "右上角"
        }
    }
}

struct ShortcutDefinition: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

struct SettingsValues: Codable, Equatable {
    var reminderEnabled = true
    var reminderIntervalMinutes = 60
    var reminderStartMinuteOfDay = 9 * 60
    var reminderEndMinuteOfDay = 22 * 60
    var reminderPosition = ReminderPosition.topCenter
    var reminderSoundEnabled: Bool? = false
    var reminderSoundName = "Glass"
    var automaticUpdatesEnabled = true
    var launchAtLogin = false
    var globalShortcut: ShortcutDefinition?
    var lastAutomaticUpdateCheckAt: Date?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case reminderEnabled
        case reminderIntervalMinutes
        case reminderStartMinuteOfDay
        case reminderEndMinuteOfDay
        case reminderPosition
        case reminderSoundEnabled
        case reminderSoundName
        case automaticUpdatesEnabled
        case launchAtLogin
        case globalShortcut
        case lastAutomaticUpdateCheckAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reminderEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .reminderEnabled
        ) ?? true
        reminderIntervalMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .reminderIntervalMinutes
        ) ?? 60
        reminderStartMinuteOfDay = try container.decodeIfPresent(
            Int.self,
            forKey: .reminderStartMinuteOfDay
        ) ?? 9 * 60
        reminderEndMinuteOfDay = try container.decodeIfPresent(
            Int.self,
            forKey: .reminderEndMinuteOfDay
        ) ?? 22 * 60
        reminderPosition = try container.decodeIfPresent(
            ReminderPosition.self,
            forKey: .reminderPosition
        ) ?? .topCenter
        reminderSoundEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .reminderSoundEnabled
        ) ?? false
        reminderSoundName = try container.decodeIfPresent(
            String.self,
            forKey: .reminderSoundName
        ) ?? "Glass"
        automaticUpdatesEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .automaticUpdatesEnabled
        ) ?? true
        launchAtLogin = try container.decodeIfPresent(
            Bool.self,
            forKey: .launchAtLogin
        ) ?? false
        globalShortcut = try container.decodeIfPresent(
            ShortcutDefinition.self,
            forKey: .globalShortcut
        )
        lastAutomaticUpdateCheckAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastAutomaticUpdateCheckAt
        )
    }
}

private struct SettingsDatabase: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var values: SettingsValues

    init(values: SettingsValues) {
        schemaVersion = Self.currentSchemaVersion
        self.values = values
    }
}

@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var values = SettingsValues()
    @Published private(set) var loadError: Error?
    @Published private(set) var saveError: Error?

    private let fileURL: URL
    private let writer: any AtomicWriting

    var reminderEnabled: Bool { values.reminderEnabled }
    var reminderIntervalMinutes: Int { values.reminderIntervalMinutes }
    var reminderStartMinuteOfDay: Int { values.reminderStartMinuteOfDay }
    var reminderEndMinuteOfDay: Int { values.reminderEndMinuteOfDay }
    var reminderPosition: ReminderPosition { values.reminderPosition }
    var reminderSoundEnabled: Bool { values.reminderSoundEnabled ?? false }
    var reminderSoundName: String { values.reminderSoundName }
    var automaticUpdatesEnabled: Bool { values.automaticUpdatesEnabled }
    var launchAtLogin: Bool { values.launchAtLogin }
    var globalShortcut: ShortcutDefinition? { values.globalShortcut }
    var lastAutomaticUpdateCheckAt: Date? { values.lastAutomaticUpdateCheckAt }

    init(fileURL: URL, writer: any AtomicWriting = AtomicFileWriter()) {
        self.fileURL = fileURL
        self.writer = writer
        load()
    }

    func update(_ mutation: (inout SettingsValues) -> Void) throws {
        guard loadError == nil else {
            throw AppSettingsError.recoveryRequired
        }
        var candidate = values
        mutation(&candidate)
        candidate.reminderPosition = candidate.reminderPosition.supportedValue
        guard [30, 60, 90, 120].contains(candidate.reminderIntervalMinutes) else {
            throw AppSettingsError.invalidReminderInterval
        }
        guard Self.isValidReminderTimeRange(
            startMinuteOfDay: candidate.reminderStartMinuteOfDay,
            endMinuteOfDay: candidate.reminderEndMinuteOfDay
        ) else {
            throw AppSettingsError.invalidReminderTimeRange
        }

        do {
            try persist(candidate)
            values = candidate
            saveError = nil
        } catch {
            saveError = error
            throw error
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let database = try decoder.decode(SettingsDatabase.self, from: data)
            guard database.schemaVersion == SettingsDatabase.currentSchemaVersion else {
                throw CocoaError(.coderInvalidValue)
            }
            var loadedValues = database.values
            loadedValues.reminderPosition = loadedValues.reminderPosition.supportedValue
            if !Self.isValidReminderTimeRange(
                startMinuteOfDay: loadedValues.reminderStartMinuteOfDay,
                endMinuteOfDay: loadedValues.reminderEndMinuteOfDay
            ) {
                loadedValues.reminderStartMinuteOfDay = 9 * 60
                loadedValues.reminderEndMinuteOfDay = 22 * 60
            }
            values = loadedValues
        } catch {
            loadError = error
        }
    }

    private func persist(_ values: SettingsValues) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SettingsDatabase(values: values))
        try writer.write(data, to: fileURL)
    }

    static func isValidReminderTimeRange(
        startMinuteOfDay: Int,
        endMinuteOfDay: Int
    ) -> Bool {
        (0..<24 * 60).contains(startMinuteOfDay) &&
            (1...24 * 60).contains(endMinuteOfDay) &&
            startMinuteOfDay < endMinuteOfDay
    }
}
