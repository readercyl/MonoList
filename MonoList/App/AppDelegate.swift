import AppKit
import Combine

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: AppDelegate?
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

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let applicationSupportURL = FileManager.default.urls(
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
            loginController.removeDevelopmentRegistration()
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
        appSettings = settings
        loginItemController = loginController
        self.reminderPanelController = reminderPanelController
        appUpdater = updater
        self.updateInstaller = updateInstaller
        windowCoordinator = coordinator
        installMenuBarObservers()
        showHomeForInteractiveLaunch()
        let initialMenuBarStatus = Self.menuBarStatus(tasks: store.tasks)
        launchMenuBarHelper(status: initialMenuBarStatus)
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
                object: nil,
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
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.openSettings() }
            },
            center.addObserver(
                forName: MenuBarBridgeProtocol.statusItemFrameChanged,
                object: nil,
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
                object: nil,
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
            try await installer.install(update)
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
                try await installer.install(update)
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
            pendingCount: tasks.filter { $0.status == .pending }.count
        )
    }

    private static func postMenuBarStatus(_ status: MenuBarStatus) {
        DistributedNotificationCenter.default().postNotificationName(
            MenuBarBridgeProtocol.pendingCountChanged,
            object: nil,
            userInfo: ["count": status.pendingCount],
            deliverImmediately: true
        )
    }

}

private struct MenuBarStatus: Equatable {
    let pendingCount: Int
}
