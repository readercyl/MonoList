import AppKit
import Combine

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: AppDelegate?
    private var taskStore: TaskStore?
    private var focusStore: FocusStore?
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
        )[0].appendingPathComponent("MonoList")
        let store = TaskStore(
            fileURL: applicationSupportURL.appendingPathComponent("tasks.json")
        )
        let focusStore = FocusStore(
            fileURL: applicationSupportURL.appendingPathComponent("focus.json")
        )
        focusStore.reconcile(existingTaskIDs: Set(store.tasks.map(\.id)))
        let settings = AppSettings(
            fileURL: applicationSupportURL.appendingPathComponent("settings.json")
        )
        let loginController = LoginItemController()
        if settings.launchAtLogin && loginController.status != .enabled {
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
        let coordinator = WindowCoordinator(taskStore: store, focusStore: focusStore)
        coordinator.configureSettings(
            settings: settings,
            reminderScheduler: scheduler,
            loginItemController: loginController,
            updater: updater,
            onInstallUpdate: { [weak self] update in
                Task { @MainActor in
                    self?.appUpdater?.beginInstallation()
                    do {
                        try await self?.updateInstaller?.install(update)
                    } catch {
                        self?.appUpdater?.installationFailed()
                        let alert = NSAlert()
                        alert.messageText = "升级失败"
                        alert.informativeText = error.localizedDescription
                        alert.addButton(withTitle: "重试")
                        alert.addButton(withTitle: "取消")
                        if alert.runModal() == .alertFirstButtonReturn {
                            self?.appUpdater?.beginInstallation()
                            do {
                                try await self?.updateInstaller?.install(update)
                            } catch {
                                self?.appUpdater?.installationFailed()
                            }
                        }
                    }
                }
            },
            onTestReminder: { [weak self] in
                self?.showReminder(testing: true)
            }
        )

        taskStore = store
        self.focusStore = focusStore
        appSettings = settings
        loginItemController = loginController
        self.reminderPanelController = reminderPanelController
        appUpdater = updater
        self.updateInstaller = updateInstaller
        windowCoordinator = coordinator
        installMenuBarObservers()
        let initialMenuBarStatus = Self.menuBarStatus(
            tasks: store.tasks,
            focusSelection: focusStore.selection
        )
        launchMenuBarHelper(status: initialMenuBarStatus)
        store.$tasks
            .combineLatest(focusStore.$selection)
            .map { tasks, selection in
                Self.menuBarStatus(tasks: tasks, focusSelection: selection)
            }
            .removeDuplicates()
            .sink { status in
                Self.postMenuBarStatus(status)
            }
            .store(in: &cancellables)

        coordinator.onWillShowMainPanel = { [weak self, weak reminderPanelController] in
            reminderPanelController?.close()
            self?.resetLightReminderAfterInteraction()
        }
        coordinator.onFocusInteraction = { [weak self] in
            self?.resetLightReminderAfterInteraction()
        }

        reminderScheduler = scheduler
        store.$tasks
            .combineLatest(settings.$values)
            .combineLatest(focusStore.$selection)
            .sink { [weak scheduler, weak reminderPanelController] pair, selection in
                let (tasks, values) = pair
                let pendingTasks = tasks.filter { $0.status == .pending }
                let lightReminderTasks = Self.lightReminderTasks(
                    tasks: tasks,
                    focusSelection: selection
                )
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

        Task {
            await updater.check(manual: false, settings: settings)
        }
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) {
            [weak updater, weak settings] _ in
            Task { @MainActor in
                guard let updater, let settings else { return }
                await updater.check(manual: false, settings: settings)
            }
        }
        dailyReminderRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) {
            [weak self, weak store, weak focusStore] _ in
            Task { @MainActor in
                try? store?.refreshDailyReminderTasks()
                if let store, let focusStore {
                    focusStore.reconcile(existingTaskIDs: Set(store.tasks.map(\.id)))
                    Self.postMenuBarStatus(
                        Self.menuBarStatus(
                            tasks: store.tasks,
                            focusSelection: focusStore.selection
                        )
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
        windowCoordinator?.toggleMainPanelFromDock()
        return true
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
        if let taskStore, let focusStore {
            focusStore.reconcile(existingTaskIDs: Set(taskStore.tasks.map(\.id)))
        }
        reminderScheduler?.wake(
            pendingCount: currentLightReminderTasks().count
        )
    }

    private func showReminder(testing: Bool = false) {
        guard taskStore != nil, let settings = appSettings else {
            reminderScheduler?.reminderClosed(pendingCount: 0)
            return
        }
        let focusPresentation = currentFocusReminderPresentation()
        let reminderTasks = currentLightReminderTasks()
        let tasks: [TaskItem]
        if let focusPresentation {
            tasks = testing
                ? ReminderPanelController.tasksForFocusTest(focusPresentation.tasks)
                : focusPresentation.tasks
        } else if testing {
            tasks = ReminderPanelController.tasksForTest(reminderTasks)
        } else {
            tasks = reminderTasks
        }
        guard !tasks.isEmpty else {
            reminderScheduler?.reminderClosed(pendingCount: 0)
            return
        }
        reminderPanelController?.show(
            tasks: tasks,
            position: settings.reminderPosition.supportedValue,
            menuBarButton: nil,
            title: focusPresentation?.title ?? "待办提醒",
            statusText: focusPresentation?.statusText,
            isFocusReminder: focusPresentation != nil,
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
            String(status.focusTaskCount ?? -1),
            status.focusCompleted ? "1" : "0",
            status.currentFocusText ?? "",
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

    private func currentLightReminderTasks(at date: Date = Date()) -> [TaskItem] {
        guard let taskStore, let focusStore else { return [] }
        return Self.lightReminderTasks(
            tasks: taskStore.tasks,
            focusSelection: focusStore.selection,
            at: date
        )
    }

    private static func lightReminderTasks(
        tasks: [TaskItem],
        focusSelection: DailyFocusSelection?,
        at date: Date = Date()
    ) -> [TaskItem] {
        ReminderScheduler.lightReminderTasks(
            in: tasks,
            focusTaskIDs: activeFocusTaskIDs(in: focusSelection, at: date)
        )
    }

    private func currentFocusReminderPresentation(
        at date: Date = Date()
    ) -> FocusReminderPresentation? {
        guard let taskStore, let focusStore, focusStore.isActive(at: date) else {
            return nil
        }
        let tasksByID = Dictionary(
            uniqueKeysWithValues: taskStore.tasks.map { ($0.id, $0) }
        )
        let focusTasks = focusStore.taskIDs(at: date).compactMap { tasksByID[$0] }
        guard let index = focusTasks.firstIndex(where: { $0.status == .pending }) else {
            return FocusReminderPresentation(
                title: "当前专注",
                statusText: "\(focusTasks.count)/\(focusTasks.count)",
                tasks: []
            )
        }
        guard focusTasks[index].group == .shortTerm else {
            return FocusReminderPresentation(
                title: "当前专注",
                statusText: "\(index + 1)/\(focusTasks.count)",
                tasks: []
            )
        }
        return FocusReminderPresentation(
            title: "当前专注",
            statusText: "\(index + 1)/\(focusTasks.count)",
            tasks: [focusTasks[index]]
        )
    }

    private func resetLightReminderAfterInteraction() {
        reminderScheduler?.meaningfulInteraction(
            pendingCount: currentLightReminderTasks().count
        )
    }

    private func reconfigureReminderScheduler() {
        guard let taskStore, let focusStore, let appSettings else { return }
        reminderScheduler?.configure(
            enabled: appSettings.reminderEnabled,
            intervalMinutes: appSettings.reminderIntervalMinutes,
            startMinuteOfDay: appSettings.reminderStartMinuteOfDay,
            endMinuteOfDay: appSettings.reminderEndMinuteOfDay,
            pendingTasks: taskStore.pendingTasks,
            lightReminderTasks: Self.lightReminderTasks(
                tasks: taskStore.tasks,
                focusSelection: focusStore.selection
            )
        )
    }

    private static func menuBarStatus(
        tasks: [TaskItem],
        focusSelection: DailyFocusSelection?,
        at date: Date = Date()
    ) -> MenuBarStatus {
        let pendingCount = tasks.filter {
            $0.status == .pending && $0.group == .shortTerm
        }.count
        guard let focusTaskIDs = activeFocusTaskIDs(
            in: focusSelection,
            at: date
        ) else {
            return MenuBarStatus(
                pendingCount: pendingCount,
                focusTaskCount: nil,
                focusCompleted: false,
                currentFocusText: nil
            )
        }
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let focusTasks = focusTaskIDs.compactMap { tasksByID[$0] }
        let pendingFocusTasks = focusTasks.filter { $0.status == .pending }
        return MenuBarStatus(
            pendingCount: pendingCount,
            focusTaskCount: focusTasks.count,
            focusCompleted: pendingFocusTasks.isEmpty,
            currentFocusText: pendingFocusTasks.first?.text
        )
    }

    private static func activeFocusTaskIDs(
        in selection: DailyFocusSelection?,
        at date: Date
    ) -> [UUID]? {
        guard let selection,
              selection.dayKey == FocusStore.dayKey(for: date),
              !selection.orderedTaskIDs.isEmpty else {
            return nil
        }
        return selection.orderedTaskIDs
    }

    private static func postMenuBarStatus(_ status: MenuBarStatus) {
        var userInfo: [String: Any] = ["count": status.pendingCount]
        if let focusTaskCount = status.focusTaskCount {
            userInfo["focusTaskCount"] = focusTaskCount
            userInfo["focusCompleted"] = status.focusCompleted
        }
        if let currentFocusText = status.currentFocusText {
            userInfo["currentFocusText"] = currentFocusText
        }
        DistributedNotificationCenter.default().postNotificationName(
            MenuBarBridgeProtocol.pendingCountChanged,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

}

private struct MenuBarStatus: Equatable {
    let pendingCount: Int
    let focusTaskCount: Int?
    let focusCompleted: Bool
    let currentFocusText: String?
}

private struct FocusReminderPresentation {
    let title: String
    let statusText: String
    let tasks: [TaskItem]
}
