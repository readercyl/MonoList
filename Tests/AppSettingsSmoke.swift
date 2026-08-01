import Foundation

@main
struct AppSettingsSmoke {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListSettingsTests-\(UUID().uuidString)")
        let fileURL = directory.appendingPathComponent("settings.json")
        let settings = AppSettings(fileURL: fileURL)

        precondition(settings.reminderEnabled)
        precondition(settings.reminderIntervalMinutes == 60)
        precondition(settings.reminderStartMinuteOfDay == 9 * 60)
        precondition(settings.reminderEndMinuteOfDay == 22 * 60)
        precondition(settings.reminderPosition == .topCenter)
        precondition(settings.reminderSoundEnabled)
        precondition(settings.reminderSoundName == "Glass")
        precondition(settings.automaticUpdatesEnabled)
        precondition(!settings.launchAtLogin)
        precondition(settings.globalShortcut == nil)
        precondition(ReminderPosition.supportedCases == [.topCenter, .topRight])
        precondition(ReminderPosition.center.supportedValue == .topCenter)
        precondition(ReminderPosition.belowMenuBar.supportedValue == .topCenter)

        try settings.update {
            $0.reminderEnabled = false
            $0.reminderIntervalMinutes = 90
            $0.reminderStartMinuteOfDay = 10 * 60
            $0.reminderEndMinuteOfDay = 21 * 60
            $0.reminderPosition = .topRight
            $0.reminderSoundEnabled = false
            $0.reminderSoundName = "Ping"
            $0.automaticUpdatesEnabled = false
            $0.globalShortcut = ShortcutDefinition(keyCode: 40, modifiers: 1 << 20)
        }

        let reloaded = AppSettings(fileURL: fileURL)
        precondition(!reloaded.reminderEnabled)
        precondition(reloaded.reminderIntervalMinutes == 90)
        precondition(reloaded.reminderStartMinuteOfDay == 10 * 60)
        precondition(reloaded.reminderEndMinuteOfDay == 21 * 60)
        precondition(reloaded.reminderPosition == .topRight)
        precondition(!reloaded.reminderSoundEnabled)
        precondition(reloaded.reminderSoundName == "Ping")
        precondition(!reloaded.automaticUpdatesEnabled)
        precondition(reloaded.globalShortcut?.keyCode == 40)

        do {
            try settings.update {
                $0.reminderStartMinuteOfDay = 22 * 60
                $0.reminderEndMinuteOfDay = 9 * 60
            }
            preconditionFailure("无效提醒时段必须被拒绝")
        } catch AppSettingsError.invalidReminderTimeRange {
        }

        let legacyURL = directory.appendingPathComponent("legacy.json")
        let legacyData = Data(
            """
            {
              "schemaVersion": 1,
              "values": {
                "reminderEnabled": true,
                "reminderIntervalMinutes": 60,
                "reminderPosition": "center",
                "launchAtLogin": true,
                "globalShortcut": null,
                "lastAutomaticUpdateCheckAt": null
              }
            }
            """.utf8
        )
        try legacyData.write(to: legacyURL)
        let legacy = AppSettings(fileURL: legacyURL)
        precondition(legacy.loadError == nil)
        precondition(legacy.reminderPosition == .topCenter)
        precondition(legacy.reminderStartMinuteOfDay == 9 * 60)
        precondition(legacy.reminderEndMinuteOfDay == 22 * 60)
        precondition(legacy.reminderSoundEnabled)
        precondition(legacy.reminderSoundName == "Glass")
        precondition(legacy.automaticUpdatesEnabled)
        precondition(legacy.launchAtLogin)

        let original = Data(#"{"schemaVersion":99,"values":{}}"#.utf8)
        let unknownURL = directory.appendingPathComponent("unknown.json")
        try original.write(to: unknownURL)
        let unknown = AppSettings(fileURL: unknownURL)
        precondition(unknown.loadError != nil)
        let unchangedData = try Data(contentsOf: unknownURL)
        precondition(unchangedData == original)

        print("App settings smoke passed.")
    }
}
