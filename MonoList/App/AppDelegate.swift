import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: AppDelegate?
    private var cliService: TaskCLIService?
    private var taskStore: TaskStore?
    private var windowCoordinator: WindowCoordinator?
    private var appSettings: AppSettings?
    private var loginItemController: LoginItemController?
    private var reminderScheduler: ReminderScheduler?
    private var reminderPanelController: ReminderPanelController?
    private var appUpdater: AppUpdater?
    private var updateInstaller: UpdateInstaller?
    private var updateCheckTimer: Timer?
    private var dailyReminderRefreshTimer: Timer?
    private var menuBarHelperApplication: NSRunningApplication?
    private var menuBarObservers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    private var isDevelopmentBuild: Bool {
        Bundle.main.bundleIdentifier == "com.qingcheng.monolist.dev"
    }

    private var applicationSupportDirectoryName: String {
        isDevelopmentBuild ? "MonoList 开发版" : "MonoList"
    }

    static func run() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isolatedPath = TaskCLI.isolatedDirectory(bundleID: Bundle.main.bundleIdentifier ?? "")
        let applicationSupportURL = isolatedPath.map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(applicationSupportDirectoryName)
        let store = TaskStore(
            fileURL: applicationSupportURL.appendingPathComponent("tasks.json")
        )
        let settings = AppSettings(
            fileURL: applicationSupportURL.appendingPathComponent("settings.json")
        )
        let loginController = LoginItemController(
            isDevelopmentBuild: isDevelopmentBuild
        )
        if isDevelopmentBuild {
            if isolatedPath == nil { loginController.removeDevelopmentRegistration() }
        } else if
            settings.launchAtLogin && loginController.status != .enabled {
            try? loginController.setEnabled(true)
        }
        try? store.refreshDailyReminderTasks()
        let reminderPanelController = ReminderPanelController()
        let scheduler = ReminderScheduler(
            onDue: { [weak self] in
                self?.showReminder()
            },
            onDedicatedReminderDue: { [weak self] id in
                self?.showDedicatedReminder(taskID: id)
            }
        )
        let updater = AppUpdater()
        let updateInstaller = UpdateInstaller()
        let coordinator = WindowCoordinator(taskStore: store)
        coordinator.configureSettings(
            settings: settings,
            reminderScheduler: scheduler,
            loginItemController: loginController,
            updater: updater,
            onInstallUpdate: { [weak self] update in
                Task { @MainActor in
                    await self?.installUpdate(update, offersRetry: true)
                }
            },
            onTestReminder: { [weak self] in
                self?.showReminder(testing: true)
            }
        )

        taskStore = store
        do {
            cliService = try TaskCLIService(name: TaskCLI.serviceName(
                bundleID: Bundle.main.bundleIdentifier ?? "com.qingcheng.monolist.dev")) { [weak self] data in
                MainActor.assumeIsolated {
                    guard let self else { return TaskCLI.failure("app_unavailable") }
                    return self.handleCLI(data)
                }
            }
        } catch {
            NSLog("MonoList CLI unavailable: %@", error.localizedDescription)
        }

        appSettings = settings
        loginItemController = loginController
        self.reminderPanelController = reminderPanelController
        appUpdater = updater
        self.updateInstaller = updateInstaller
        windowCoordinator = coordinator
        installMenuBarObservers()
        if isolatedPath == nil { showHomeForInteractiveLaunch() }
        let initialMenuBarStatus = Self.menuBarStatus(tasks: store.tasks)
        if isolatedPath == nil { launchMenuBarHelper(status: initialMenuBarStatus) }
        store.$tasks
            .map { tasks in Self.menuBarStatus(tasks: tasks) }
            .removeDuplicates()
            .sink { status in
                Self.postMenuBarStatus(status)
            }
            .store(in: &cancellables)

        coordinator.onWillShowMainPanel = { [weak self, weak reminderPanelController] in
            reminderPanelController?.close()
            self?.resetLightReminderAfterInteraction()
        }
        reminderScheduler = scheduler
        store.$tasks
            .combineLatest(settings.$values)
            .sink { [weak scheduler, weak reminderPanelController] pair in
                let (tasks, values) = pair
                let pendingTasks = tasks.filter { $0.status == .pending }
                let lightReminderTasks = Self.lightReminderTasks(tasks: tasks)
                scheduler?.configure(
                    enabled: values.reminderEnabled,
                    intervalMinutes: values.reminderIntervalMinutes,
                    startMinuteOfDay: values.reminderStartMinuteOfDay,
                    endMinuteOfDay: values.reminderEndMinuteOfDay,
                    pendingTasks: pendingTasks,
                    lightReminderTasks: lightReminderTasks
                )
                if (!values.reminderEnabled || lightReminderTasks.isEmpty) &&
                    reminderPanelController?.isDedicatedReminder != true {
                    reminderPanelController?.close()
                }
            }
            .store(in: &cancellables)
        scheduler.startPolling { [weak self] in
            guard let self else { return true }
            return self.windowCoordinator?.isMainPanelVisible == true ||
                self.windowCoordinator?.isSettingsVisible == true ||
                self.reminderPanelController?.isVisible == true
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        if !isDevelopmentBuild {
            Task { [weak self] in
                await self?.checkForAutomaticUpdate()
            }
            updateCheckTimer = Timer.scheduledTimer(
                withTimeInterval: 60 * 60,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in
                    await self?.checkForAutomaticUpdate()
                }
            }
        }
        dailyReminderRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
            [weak self, weak store] _ in
            Task { @MainActor in
                try? store?.refreshDailyReminderTasks()
                if let store {
                    Self.postMenuBarStatus(
                        Self.menuBarStatus(tasks: store.tasks)
                    )
                    self?.reconfigureReminderScheduler()
                }
            }
        }
    }

    private func handleCLI(_ data: Data) -> Data {
        do {
            guard let store = taskStore, let settings = appSettings,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let command = object["command"] as? String else {
                throw TaskCLIError.message("invalid_request")
            }
            func json<T: Encodable>(_ value: T) throws -> Any {
                try JSONSerialization.jsonObject(with: TaskCLI.encode(value))
            }
            func confirmed() throws {
                guard object["confirm"] as? Bool == true else {
                    throw TaskCLIError.message("此操作需要 confirm:true")
                }
            }
            let result: Any
            switch command {
            case "list": result = try json(store.cliSnapshot())
            case "apply":
                guard TaskExpansionState.shared.activeEditors.isEmpty else {
                    throw TaskCLIError.message("editor_busy: 请先结束界面中的任务编辑")
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                result = try json(store.applyCLI(decoder.decode(TaskCLIBatch.self, from: data)))
            case "status":
                result = ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                          "development": isDevelopmentBuild,
                          "pendingCount": store.pendingTasks.count,
                          "menuBarCount": TaskStore.pendingActionCount(in: store.tasks),
                          "nextReminderDate": reminderScheduler?.nextReminderDate.map {
                              ISO8601DateFormatter().string(from: $0)
                          } ?? "",
                          "reminderVisible": reminderPanelController?.isVisible ?? false,
                          "settingsVisible": windowCoordinator?.isSettingsVisible ?? false,
                          "completedCount": store.historyTasks.count,
                          "editorBusy": !TaskExpansionState.shared.activeEditors.isEmpty,
                          "loadError": store.loadError?.localizedDescription ?? "",
                          "writePaused": store.isWritePaused,
                          "login": loginItemController?.statusText ?? "",
                          "homeVisible": windowCoordinator?.isHomeVisible ?? false,
                          "panelVisible": windowCoordinator?.isMainPanelVisible ?? false] as [String: Any]
            case "settings.get":
                result = ["revision": try TaskCLI.revision(settings.values),
                          "values": try json(settings.values)]
            case "settings.set":
                guard object["expectedRevision"] as? String == (try TaskCLI.revision(settings.values)),
                      let patch = object["values"] as? [String: Any], !patch.isEmpty else {
                    throw TaskCLIError.message("settings_conflict_or_missing_values: 请先 settings.get")
                }
                let fields: Set<String> = ["reminderEnabled", "reminderIntervalMinutes",
                    "reminderStartMinuteOfDay", "reminderEndMinuteOfDay", "reminderPosition",
                    "reminderSoundEnabled", "reminderSoundName", "automaticUpdatesEnabled"]
                guard Set(patch.keys).isSubset(of: fields), !patch.values.contains(where: { $0 is NSNull }) else {
                    throw TaskCLIError.message("未知或只读设置；开机启动请用 login.set")
                }
                var merged = try json(settings.values) as! [String: Any]
                merged.merge(patch) { _, new in new }
                let candidate = try JSONDecoder().decode(SettingsValues.self,
                    from: JSONSerialization.data(withJSONObject: merged))
                guard [30, 60, 90, 120].contains(candidate.reminderIntervalMinutes),
                      AppSettings.isValidReminderTimeRange(startMinuteOfDay: candidate.reminderStartMinuteOfDay,
                        endMinuteOfDay: candidate.reminderEndMinuteOfDay),
                      ReminderPosition.supportedCases.contains(candidate.reminderPosition),
                      SettingsView.systemSoundNames.contains(candidate.reminderSoundName) else {
                    throw TaskCLIError.message("设置值不在界面允许的范围内")
                }
                try settings.backupForCLI()
                try settings.update { $0 = candidate }
                result = ["revision": try TaskCLI.revision(settings.values), "values": try json(settings.values)]
            case "login.set":
                try confirmed()
                guard let enabled = object["enabled"] as? Bool, let controller = loginItemController else {
                    throw TaskCLIError.message("缺少 enabled")
                }
                guard !isDevelopmentBuild else { throw LoginItemControllerError.developmentBuildReadOnly }
                let previous = settings.launchAtLogin
                try settings.backupForCLI()
                try controller.setEnabled(enabled)
                do { try settings.update { $0.launchAtLogin = enabled } }
                catch {
                    do { try controller.setEnabled(previous) }
                    catch { throw TaskCLIError.message("设置保存和启动项恢复均失败，请在系统设置检查启动项") }
                    throw error
                }
                result = ["status": controller.statusText]
            case "view.get":
                let state = TaskExpansionState.shared
                result = ["collapsedIDs": state.collapsedTaskIDs.map(\.uuidString).sorted(),
                          "homeHistory": state.homeHistory, "panelHistory": state.panelHistory] as [String: Any]
            case "view.set":
                let state = TaskExpansionState.shared
                let fields: Set<String> = ["collapsedIDs", "homeHistory", "panelHistory"]
                let supplied = Set(object.keys).subtracting(["command"])
                guard !supplied.isEmpty, supplied.isSubset(of: fields) else {
                    throw TaskCLIError.message("view.set 需要 collapsedIDs、homeHistory 或 panelHistory")
                }
                var collapsedIDs: Set<UUID>?
                if let rawIDs = object["collapsedIDs"] {
                    guard let ids = rawIDs as? [String], ids.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                        throw TaskCLIError.message("collapsedIDs 必须是 UUID 数组")
                    }
                    collapsedIDs = Set(ids.compactMap(UUID.init(uuidString:)))
                }
                for field in ["homeHistory", "panelHistory"] where object[field] != nil {
                    guard object[field] is Bool else { throw TaskCLIError.message("历史开关必须为布尔值") }
                }
                if let collapsedIDs { state.collapsedTaskIDs = collapsedIDs }
                if let show = object["homeHistory"] as? Bool { state.homeHistory = show }
                if let show = object["panelHistory"] as? Bool { state.panelHistory = show }
                result = ["updated": true]
            case "window.home": windowCoordinator?.showHome(); result = ["shown": true]
            case "window.settings": windowCoordinator?.showSettings(); result = ["shown": true]
            case "window.panel": showOrFocusMainPanelAtFallback(); result = ["shown": true]
            case "window.hide":
                windowCoordinator?.hideWindowsForCLI()
                result = ["hidden": true]
            case "reminder.test": showReminder(testing: true); result = ["shown": true]
            case "reminder.close": reminderPanelController?.close(); result = ["closed": true]
            case "data.retry-load":
                try confirmed()
                guard store.loadError != nil else { throw TaskCLIError.message("没有需要恢复的读取错误") }
                store.retryLoad()
                result = try json(store.cliSnapshot())
            case "data.retry-save": try store.retryPersist(); result = try json(store.cliSnapshot())
            case "update.check":
                guard let updater = appUpdater else { throw TaskCLIError.message("updater_unavailable") }
                Task { _ = await updater.check(manual: true, settings: settings) }
                result = ["accepted": true, "poll": "update.status"]
            case "update.status":
                result = ["checking": appUpdater?.isChecking ?? false,
                          "installing": appUpdater?.isInstalling ?? false,
                          "status": appUpdater?.statusText ?? "",
                          "availableVersion": appUpdater?.availableUpdate?.version ?? ""] as [String: Any]
            case "update.install":
                try confirmed()
                guard !isDevelopmentBuild, let update = appUpdater?.availableUpdate,
                      appUpdater?.isInstalling == false else {
                    throw TaskCLIError.message("开发版禁止升级，或尚无可安装版本；先 update.check")
                }
                Task { await self.installUpdate(update, offersRetry: false) }
                result = ["accepted": true, "poll": "update.status"]
            case "app.quit":
                try confirmed()
                guard TaskExpansionState.shared.activeEditors.isEmpty else {
                    throw TaskCLIError.message("editor_busy")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                result = ["accepted": true]
            default: throw TaskCLIError.message("未知 command，请运行 help")
            }
            return try JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
        } catch { return TaskCLI.failure(error.localizedDescription) }
    }

    @objc
    private func openSettings() {
        windowCoordinator?.closeMainPanel()
        windowCoordinator?.showSettings()
    }

    @objc
    private func quitApplication() {
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        windowCoordinator?.showHome()
        return true
    }

    private func showHomeForInteractiveLaunch() {
        DispatchQueue.main.async { [weak self] in
            let currentProcessID = ProcessInfo.processInfo.processIdentifier
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier ==
                currentProcessID
            guard NSApp.isActive || isFrontmost else { return }
            self?.windowCoordinator?.showHome()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateCheckTimer?.invalidate()
        dailyReminderRefreshTimer?.invalidate()
        menuBarHelperApplication?.terminate()
        for observer in menuBarObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    @objc
    private func systemDidWake() {
        try? taskStore?.refreshDailyReminderTasks()
        reminderScheduler?.wake(
            pendingCount: currentLightReminderTasks().count
        )
    }

    private func showReminder(testing: Bool = false) {
        guard let settings = appSettings else {
            reminderScheduler?.reminderClosed(pendingCount: 0)
            return
        }
        let reminderTasks = currentLightReminderTasks()
        let tasks = testing
            ? ReminderPanelController.tasksForTest(reminderTasks)
            : reminderTasks
        guard !tasks.isEmpty else {
            reminderScheduler?.reminderClosed(pendingCount: 0)
            return
        }
        reminderPanelController?.show(
            tasks: tasks,
            position: settings.reminderPosition.supportedValue,
            menuBarButton: nil,
            title: "待办提醒",
            testing: testing,
            playsSound: settings.reminderSoundEnabled,
            soundName: settings.reminderSoundName,
            onOpen: { [weak self] in
                self?.showOrFocusMainPanelAtFallback()
            },
            onClose: { [weak self] in
                if !testing {
                    self?.reminderScheduler?.reminderClosed(
                        pendingCount: self?.currentLightReminderTasks().count ?? 0
                    )
                }
            }
        )
    }

    private func showDedicatedReminder(taskID: UUID) {
        guard let store = taskStore,
              let settings = appSettings,
              let task = store.pendingTasks.first(where: { $0.id == taskID }) else {
            return
        }
        try? store.markDedicatedReminderTriggered(id: taskID)
        reminderPanelController?.show(
            tasks: [task],
            position: settings.reminderPosition.supportedValue,
            menuBarButton: nil,
            title: "定时提醒",
            isDedicatedReminder: true,
            playsSound: settings.reminderSoundEnabled,
            soundName: settings.reminderSoundName,
            onOpen: { [weak self] in
                self?.showOrFocusMainPanelAtFallback()
            },
            onClose: {}
        )
    }

    private func installMenuBarObservers() {
        let center = DistributedNotificationCenter.default()
        menuBarObservers = [
            center.addObserver(
                forName: MenuBarBridgeProtocol.showMainPanel,
                object: MenuBarBridgeProtocol.channel(parentProcessID: ProcessInfo.processInfo.processIdentifier),
                queue: .main
            ) { [weak self] notification in
                guard let xNumber = notification.userInfo?["x"] as? NSNumber,
                      let yNumber = notification.userInfo?["y"] as? NSNumber else {
                    return
                }
                Task { @MainActor in
                    self?.windowCoordinator?.toggleMainPanel(
                        at: NSPoint(
                            x: CGFloat(truncating: xNumber),
                            y: CGFloat(truncating: yNumber)
                        )
                    )
                }
            },
            center.addObserver(
                forName: MenuBarBridgeProtocol.openSettings,
                object: MenuBarBridgeProtocol.channel(parentProcessID: ProcessInfo.processInfo.processIdentifier),
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.openSettings() }
            },
            center.addObserver(
                forName: MenuBarBridgeProtocol.statusItemFrameChanged,
                object: MenuBarBridgeProtocol.channel(parentProcessID: ProcessInfo.processInfo.processIdentifier),
                queue: .main
            ) { [weak self] notification in
                let values = notification.userInfo
                guard let xNumber = values?["x"] as? NSNumber,
                      let yNumber = values?["y"] as? NSNumber,
                      let widthNumber = values?["width"] as? NSNumber,
                      let heightNumber = values?["height"] as? NSNumber,
                      let anchorXNumber = values?["anchorX"] as? NSNumber,
                      let anchorYNumber = values?["anchorY"] as? NSNumber else {
                    return
                }
                Task { @MainActor in
                    self?.windowCoordinator?.updateMenuBarLocation(
                        anchor: NSPoint(
                            x: CGFloat(truncating: anchorXNumber),
                            y: CGFloat(truncating: anchorYNumber)
                        ),
                        buttonFrame: NSRect(
                            x: CGFloat(truncating: xNumber),
                            y: CGFloat(truncating: yNumber),
                            width: CGFloat(truncating: widthNumber),
                            height: CGFloat(truncating: heightNumber)
                        )
                    )
                }
            },
            center.addObserver(
                forName: MenuBarBridgeProtocol.quit,
                object: MenuBarBridgeProtocol.channel(parentProcessID: ProcessInfo.processInfo.processIdentifier),
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.quitApplication() }
            },
        ]
    }

    private func launchMenuBarHelper(status: MenuBarStatus) {
        let helperURL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/Helpers/MenuBarService.app"
        )
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.arguments = [
            String(ProcessInfo.processInfo.processIdentifier),
            String(status.pendingCount),
        ]
        NSWorkspace.shared.openApplication(
            at: helperURL,
            configuration: configuration
        ) { [weak self] application, error in
            Task { @MainActor in
                if let error {
                    NSLog("MonoList menu bar service failed to launch: %@", error.localizedDescription)
                }
                self?.menuBarHelperApplication = application
            }
        }
    }

    private func showOrFocusMainPanelAtFallback() {
        windowCoordinator?.showOrFocusMainPanelFromMenuBar()
    }

    private func checkForAutomaticUpdate() async {
        guard !isDevelopmentBuild else { return }
        guard let updater = appUpdater,
              let settings = appSettings,
              let update = await updater.check(manual: false, settings: settings),
              settings.automaticUpdatesEnabled else {
            return
        }
        await installUpdate(update, offersRetry: false)
    }

    private func installUpdate(
        _ update: AppUpdate,
        offersRetry: Bool
    ) async {
        guard !isDevelopmentBuild else { return }
        guard let updater = appUpdater,
              let installer = updateInstaller,
              !updater.isInstalling else {
            return
        }
        updater.beginInstallation()
        do {
            try await installer.install(update, helperProcessID: menuBarHelperApplication?.processIdentifier)
        } catch {
            updater.installationFailed()
            guard offersRetry else { return }

            let alert = NSAlert()
            alert.messageText = "升级失败"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "重试")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            updater.beginInstallation()
            do {
                try await installer.install(update, helperProcessID: menuBarHelperApplication?.processIdentifier)
            } catch {
                updater.installationFailed()
            }
        }
    }

    private func currentLightReminderTasks() -> [TaskItem] {
        guard let taskStore else { return [] }
        return Self.lightReminderTasks(tasks: taskStore.tasks)
    }

    private static func lightReminderTasks(tasks: [TaskItem]) -> [TaskItem] {
        return ReminderScheduler.lightReminderTasks(in: tasks)
    }

    private func resetLightReminderAfterInteraction() {
        reminderScheduler?.meaningfulInteraction(
            pendingCount: currentLightReminderTasks().count
        )
    }

    private func reconfigureReminderScheduler() {
        guard let taskStore, let appSettings else { return }
        reminderScheduler?.configure(
            enabled: appSettings.reminderEnabled,
            intervalMinutes: appSettings.reminderIntervalMinutes,
            startMinuteOfDay: appSettings.reminderStartMinuteOfDay,
            endMinuteOfDay: appSettings.reminderEndMinuteOfDay,
            pendingTasks: taskStore.pendingTasks,
            lightReminderTasks: Self.lightReminderTasks(tasks: taskStore.tasks)
        )
    }

    private static func menuBarStatus(tasks: [TaskItem]) -> MenuBarStatus {
        MenuBarStatus(
            pendingCount: TaskStore.pendingActionCount(in: tasks)
        )
    }

    private static func postMenuBarStatus(_ status: MenuBarStatus) {
        guard TaskCLI.isolatedDirectory(bundleID: Bundle.main.bundleIdentifier ?? "") == nil else { return }
        DistributedNotificationCenter.default().postNotificationName(
            MenuBarBridgeProtocol.pendingCountChanged,
            object: MenuBarBridgeProtocol.channel(parentProcessID: ProcessInfo.processInfo.processIdentifier),
            userInfo: ["count": status.pendingCount],
            deliverImmediately: true
        )
    }

}

private struct MenuBarStatus: Equatable {
    let pendingCount: Int
}
