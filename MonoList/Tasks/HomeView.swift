import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum HomeSection: String {
    case tasks
    case settings
}

@MainActor
final class HomePresentationState: ObservableObject {
    @Published var section: HomeSection = .tasks
}

struct HomeView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var presentation: HomePresentationState
    @ObservedObject var settings: AppSettings
    @ObservedObject var reminderScheduler: ReminderScheduler
    @ObservedObject var loginItemController: LoginItemController
    @ObservedObject var updater: AppUpdater
    let onInstallUpdate: (AppUpdate) -> Void
    let onTestReminder: () -> Void
    let onWindowReady: () -> Void

    @StateObject private var draftState = TaskDraftState()
    @State private var currentDate = Date()
    @State private var collapsedTaskIDs: Set<UUID> = []
    @State private var selectedTaskID: UUID?
    @State private var editingTaskID: UUID?
    @State private var draftFocused = false
    @State private var draftRequestID = UUID()
    @State private var errorMessage: String?
    @State private var showsOlderCompleted = true
    @State private var clearAction: HomeClearAction?
    @StateObject private var dropCoordinator = TaskDropCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var todayCompletedRoots: [TaskItem] {
        store.completedTasks(on: currentDate).filter { $0.parentID == nil }
    }

    private var olderCompletedGroups: [HomeCompletedGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(
            grouping: store.completedTasks(before: currentDate).filter { $0.parentID == nil }
        ) { calendar.startOfDay(for: $0.completedAt ?? $0.updatedAt) }
        return grouped
            .map { HomeCompletedGroup(date: $0.key, tasks: $0.value) }
            .sorted { $0.date > $1.date }
    }

    private var hasOlderCompleted: Bool {
        !olderCompletedGroups.isEmpty
    }

    var body: some View {
        Group {
            if let loadError = store.loadError {
                DataRecoveryView(
                    message: loadError.localizedDescription,
                    onRetry: { store.retryLoad() },
                    onQuit: { NSApp.terminate(nil) }
                )
            } else if presentation.section == .settings {
                settingsContent
            } else {
                taskContent
            }
        }
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
        .confirmationDialog(
            clearAction?.title ?? "",
            isPresented: Binding(
                get: { clearAction != nil },
                set: { if !$0 { clearAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(clearAction?.buttonTitle ?? "永久删除", role: .destructive) {
                performClear()
            }
            Button("取消", role: .cancel) { clearAction = nil }
        } message: {
            Text(clearAction?.message ?? "")
        }
        .onAppear {
            syncDraftVisibility()
            onWindowReady()
        }
        .onChange(of: store.tasks) { _, _ in
            if !draftState.isPresented {
                syncDraftVisibility()
            }
        }
        .onDisappear {
            commitDraft()
        }
        .onReceive(
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
        ) { date in
            currentDate = date
        }
    }

    private var taskContent: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.45)
            ScrollViewReader { proxy in
                ScrollView {
                    taskList
                        .onTapGesture {
                            clearInteraction()
                        }
                }
                .onChange(of: draftRequestID) { _, _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo("home-task-draft-row", anchor: .bottom)
                        }
                        draftFocused = true
                    }
                }
            }
            .scrollBounceBehavior(.always, axes: .vertical)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    presentation.section = .tasks
                } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .help("返回待办")

                WindowDragArea()
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)

                Text("设置")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 42)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)

            Divider().opacity(0.45)

            SettingsView(
                settings: settings,
                taskStore: store,
                reminderScheduler: reminderScheduler,
                loginItemController: loginItemController,
                updater: updater,
                onInstallUpdate: onInstallUpdate,
                onTestReminder: onTestReminder
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今天")
                    .font(.system(size: 17, weight: .semibold))
                Text(currentDate, format: .dateTime.month().day().weekday())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .simultaneousGesture(
                    TapGesture().onEnded { clearInteraction() }
                )

            Button {
                beginRootDraft()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(HomeHeaderIconButtonStyle())
            .help("新增待办")

            Menu {
                Button("清空未完成任务") { clearAction = .pending }
                    .disabled(store.pendingTasks.isEmpty)
                Button("清空已完成任务") { clearAction = .completed }
                    .disabled(store.historyTasks.isEmpty)
                Divider()
                Button("清空全部任务", role: .destructive) { clearAction = .all }
                    .disabled(store.tasks.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(HomeHeaderIconButtonStyle())
            .help("更多操作")

            Button {
                clearInteraction()
                presentation.section = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(HomeHeaderIconButtonStyle())
            .help("设置")
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
    }

    private var taskList: some View {
        VStack(alignment: .leading, spacing: 22) {
            pendingSection
            completedSection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("未完成")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(store.pendingTasks.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 8)

            let roots = store.topLevelPendingTasks
            if roots.isEmpty && !(draftState.isPresented && draftState.parentID == nil) {
                Text("还没有任务")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            }

            ForEach(Array(roots.enumerated()), id: \.element.id) { index, root in
                taskTree(
                    for: root,
                    priorityRank: index < 3 ? index : nil
                )
                if draftState.isPresented,
                   draftState.parentID == nil,
                   draftState.afterID == root.id {
                    draftRow(indentationLevel: 0)
                }
            }

            if draftState.isPresented,
               draftState.parentID == nil,
               draftState.afterID == nil {
                draftRow(indentationLevel: 0)
            }
        }
    }

    @ViewBuilder
    private func taskTree(for root: TaskItem, priorityRank: Int?) -> some View {
        let children = store.children(of: root.id)
        VStack(alignment: .leading, spacing: 1) {
            pendingTaskRow(
                root,
                indentationLevel: 0,
                priorityRank: priorityRank,
                hasSubtasks: !children.isEmpty,
                dropParentID: nil,
                dropUpperBeforeID: root.id,
                dropLowerBeforeID: nil
            )

            if !collapsedTaskIDs.contains(root.id) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    if child.status == .pending {
                        pendingTaskRow(
                            child,
                            indentationLevel: 1,
                            priorityRank: nil,
                            hasSubtasks: false,
                            dropParentID: root.id,
                            dropUpperBeforeID: child.id,
                            dropLowerBeforeID: children.indices.contains(index + 1)
                                ? children[index + 1].id
                                : nil
                        )
                    } else {
                        HomeCompletedTaskRow(
                            item: child,
                            onRestore: { restoreTask(child) },
                            onDelete: { deleteTask(child) },
                            indentationLevel: 1
                        )
                    }
                    if draftState.isPresented,
                       draftState.parentID == root.id,
                       draftState.afterID == child.id {
                        draftRow(indentationLevel: 1)
                    }
                }
                if draftState.isPresented && draftState.parentID == root.id,
                   draftState.afterID == nil {
                    draftRow(indentationLevel: 1)
                }
            }
        }
    }

    private func pendingTaskRow(
        _ item: TaskItem,
        indentationLevel: Int,
        priorityRank: Int?,
        hasSubtasks: Bool,
        dropParentID: UUID?,
        dropUpperBeforeID: UUID?,
        dropLowerBeforeID: UUID?
    ) -> some View {
        TaskRowView(
            item: item,
            onSave: { updateText(item, text: $0) },
            onComplete: { text in completeTask(item, finalText: text) },
            onDelete: { deleteTask(item) },
            onMoveUp: { moveTask(item, by: -1) },
            onMoveDown: { moveTask(item, by: 1) },
            onInsertAfter: {
                beginDraft(after: item.id, parentID: item.parentID)
            },
            onUpdateReminder: { updateReminder(item, reminder: $0) },
            isSelected: selectedTaskID == item.id,
            onSelect: { selectedTaskID = item.id },
            onEditingChanged: { editing in
                editingTaskID = editing ? item.id : nil
            },
            indentationLevel: indentationLevel,
            hasSubtasks: hasSubtasks,
            isExpanded: !collapsedTaskIDs.contains(item.id),
            onToggleSubtasks: { toggleExpanded(item.id) },
            onAddSubtask: indentationLevel == 0
                ? { beginSubtaskDraft(for: item) }
                : nil,
            canAddSubtask: indentationLevel == 0,
            onIndent: {
                performHierarchyChange {
                    try store.indent(id: item.id)
                    return item.parentID == nil
                }
            },
            onOutdent: {
                performHierarchyChange {
                    guard item.parentID != nil else { return false }
                    try store.outdent(id: item.id)
                    return true
                }
            },
            subtaskProgressText: store.subtaskProgressText(for: item.id),
            priorityRank: priorityRank
        )
        .overlay(alignment: .top) {
            if dropCoordinator.target == TaskDropTarget(
                group: .shortTerm,
                beforeID: item.id,
                parentID: dropParentID
            ) {
                HomeTaskDragInsertionIndicator()
            }
        }
        .overlay(alignment: .bottom) {
            if dropLowerBeforeID == nil,
               dropCoordinator.target == TaskDropTarget(
                   group: .shortTerm,
                   beforeID: nil,
                   parentID: dropParentID
               ) {
                HomeTaskDragInsertionIndicator()
            }
        }
        .onDrag {
            dropCoordinator.beginDragging(task: item)
            return NSItemProvider(object: item.id.uuidString as NSString)
        } preview: {
            HomeTaskDragPreview(text: item.text, priorityRank: priorityRank)
        }
        .onDrop(
            of: [UTType.text],
            delegate: HomeTaskDropDelegate(
                group: .shortTerm,
                parentID: dropParentID,
                upperBeforeID: dropUpperBeforeID,
                lowerBeforeID: dropLowerBeforeID,
                rowHeight: 40,
                sessionID: dropCoordinator.sessionID,
                store: store,
                coordinator: dropCoordinator,
                errorMessage: $errorMessage
            )
        )
    }

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("已完成")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(store.historyTasks.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                if hasOlderCompleted {
                    Button(showsOlderCompleted ? "隐藏较早记录" : "显示较早记录") {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                            showsOlderCompleted.toggle()
                        }
                    }
                    .buttonStyle(HomeInlineButtonStyle())
                }
            }
            .padding(.horizontal, 8)

            if todayCompletedRoots.isEmpty && olderCompletedGroups.isEmpty {
                Text("完成的任务会显示在这里")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                if !todayCompletedRoots.isEmpty {
                    completedDateHeader(currentDate, isToday: true)
                    ForEach(todayCompletedRoots) { root in
                        completedTree(for: root)
                    }
                }
                if showsOlderCompleted {
                    ForEach(olderCompletedGroups, id: \.date) { group in
                        completedDateHeader(group.date, isToday: false)
                        ForEach(group.tasks) { root in
                            completedTree(for: root)
                        }
                    }
                }
            }
        }
    }

    private func completedDateHeader(_ date: Date, isToday: Bool) -> some View {
        Text(isToday ? "今天" : date.formatted(.dateTime.year().month().day()))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .padding(.bottom, 1)
    }

    @ViewBuilder
    private func completedTree(for root: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HomeCompletedTaskRow(
                item: root,
                onRestore: { restoreTask(root) },
                onDelete: { deleteTask(root) },
                indentationLevel: 0,
                hasSubtasks: !store.children(of: root.id).isEmpty,
                isExpanded: !collapsedTaskIDs.contains(root.id),
                onToggleSubtasks: { toggleExpanded(root.id) }
            )
            if !collapsedTaskIDs.contains(root.id) {
                ForEach(store.children(of: root.id)) { child in
                    HomeCompletedTaskRow(
                        item: child,
                        onRestore: { restoreTask(child) },
                        onDelete: { deleteTask(child) },
                        indentationLevel: 1
                    )
                }
            }
        }
    }

    private func toggleExpanded(_ id: UUID) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            if collapsedTaskIDs.contains(id) {
                collapsedTaskIDs.remove(id)
            } else {
                collapsedTaskIDs.insert(id)
            }
        }
    }

    private func beginRootDraft() {
        commitDraft()
        beginDraft(after: store.topLevelPendingTasks.last?.id, parentID: nil)
    }

    private func beginSubtaskDraft(for parent: TaskItem) {
        commitDraft()
        collapsedTaskIDs.remove(parent.id)
        beginDraft(after: store.children(of: parent.id).last?.id, parentID: parent.id)
    }

    private func beginDraft(after id: UUID?, parentID: UUID?) {
        selectedTaskID = nil
        editingTaskID = nil
        draftState.present(after: id, in: .shortTerm, parentID: parentID)
        draftRequestID = UUID()
        DispatchQueue.main.async { draftFocused = true }
    }

    private func draftRow(indentationLevel: Int) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Color.clear.frame(
                width: indentationLevel == 0 ? 0 : 20,
                height: 28
            )
            Image(systemName: "circle")
                .font(.system(size: 17))
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)
            TaskTextEditor(
                text: $draftState.text,
                isFocused: $draftFocused,
                onSubmit: continueDraft,
                onIndent: { indentDraft() },
                onOutdent: { outdentDraft() }
            )
            .onAppear {
                DispatchQueue.main.async { draftFocused = true }
            }
            .onChange(of: draftFocused) { oldValue, newValue in
                if oldValue && !newValue {
                    commitDraft()
                }
            }
            .padding(.vertical, 5)
            Color.clear.frame(width: 28, height: 28)
        }
        .padding(.leading, CGFloat(indentationLevel) * 21 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
        .id("home-task-draft-row")
    }

    private func indentDraft() -> Bool {
        guard draftState.parentID == nil else { return false }
        let roots = store.topLevelPendingTasks
        guard let afterID = draftState.afterID,
              let index = roots.firstIndex(where: { $0.id == afterID }),
              index > 0 else {
            return false
        }
        let parent = roots[index - 1]
        draftState.parentID = parent.id
        draftState.afterID = store.children(of: parent.id).last?.id
        collapsedTaskIDs.remove(parent.id)
        return true
    }

    private func outdentDraft() -> Bool {
        guard let parentID = draftState.parentID else { return false }
        draftState.parentID = nil
        draftState.afterID = parentID
        return true
    }

    private func syncDraftVisibility() {
        draftState.syncVisibility(hasPendingTasks: !store.pendingTasks.isEmpty)
    }

    private func commitDraft() {
        guard draftState.isPresented else { return }
        do {
            try draftState.commitOrDismiss(to: store)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func continueDraft() {
        guard draftState.isPresented else { return }
        do {
            _ = try draftState.submitAndContinue(to: store)
            draftRequestID = UUID()
            DispatchQueue.main.async { draftFocused = true }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearInteraction() {
        commitDraft()
        selectedTaskID = nil
        editingTaskID = nil
        draftFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func updateText(_ item: TaskItem, text: String) {
        performAction { try store.updateText(id: item.id, text: text) }
    }

    @discardableResult
    private func completeTask(_ item: TaskItem, finalText: String) -> Bool {
        performAction { try store.complete(id: item.id, finalText: finalText) }
    }

    private func deleteTask(_ item: TaskItem) {
        performAction { try store.delete(id: item.id) }
        selectedTaskID = nil
    }

    private func restoreTask(_ item: TaskItem) {
        performAction { try store.restore(id: item.id) }
    }

    private func moveTask(_ item: TaskItem, by offset: Int) {
        performAction { try store.move(id: item.id, by: offset) }
    }

    private func updateReminder(_ item: TaskItem, reminder: TaskReminder?) {
        performAction { try store.updateReminder(id: item.id, reminder: reminder) }
    }

    private func performClear() {
        guard let clearAction else { return }
        performAction {
            switch clearAction {
            case .pending: try store.clearPending()
            case .completed: try store.clearHistory()
            case .all: try store.clearAll()
            }
        }
        selectedTaskID = nil
        self.clearAction = nil
    }

    @discardableResult
    private func performAction(_ action: () throws -> Void) -> Bool {
        do {
            try action()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func performHierarchyChange(_ action: () throws -> Bool) -> Bool {
        do {
            return try action()
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

private enum HomeClearAction {
    case pending
    case completed
    case all

    var title: String {
        switch self {
        case .pending: return "清空未完成任务？"
        case .completed: return "清空已完成任务？"
        case .all: return "清空全部任务？"
        }
    }

    var buttonTitle: String {
        switch self {
        case .pending: return "删除所有未完成任务"
        case .completed: return "删除所有已完成任务"
        case .all: return "删除全部任务"
        }
    }

    var message: String { "此操作会立即永久删除对应任务，且无法撤销。" }
}

private struct HomeCompletedGroup {
    let date: Date
    let tasks: [TaskItem]
}

private struct HomeHeaderIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
    }
}

private struct HomeInlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(
                configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
    }
}

private struct HomeCompletedTaskRow: View {
    let item: TaskItem
    let onRestore: () -> Void
    let onDelete: () -> Void
    let indentationLevel: Int
    let hasSubtasks: Bool
    let isExpanded: Bool
    let onToggleSubtasks: () -> Void

    @State private var isHovered = false

    init(
        item: TaskItem,
        onRestore: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        indentationLevel: Int,
        hasSubtasks: Bool = false,
        isExpanded: Bool = true,
        onToggleSubtasks: @escaping () -> Void = {}
    ) {
        self.item = item
        self.onRestore = onRestore
        self.onDelete = onDelete
        self.indentationLevel = indentationLevel
        self.hasSubtasks = hasSubtasks
        self.isExpanded = isExpanded
        self.onToggleSubtasks = onToggleSubtasks
    }

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            if hasSubtasks {
                Button(action: onToggleSubtasks) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 20, height: 28)
                }
                .buttonStyle(.plain)
            } else if indentationLevel > 0 {
                Color.clear.frame(width: 20, height: 28)
            }

            Button(action: onRestore) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("恢复为未完成")

            Text(item.text)
                .font(.system(size: 13))
                .strikethrough()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .opacity(isHovered ? 1 : 0)
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.leading, CGFloat(indentationLevel) * 21 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("恢复为未完成", action: onRestore)
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}

private struct HomeTaskDragPreview: View {
    let text: String
    let priorityRank: Int?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "circle")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
            Text(text)
                .font(.system(size: fontSize, weight: fontWeight))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: 360)
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
    }

    private var fontSize: CGFloat {
        switch priorityRank {
        case 0: return 18
        case 1: return 16
        case 2: return 14
        default: return 13
        }
    }

    private var fontWeight: Font.Weight {
        priorityRank == 0 ? .semibold : .regular
    }
}

private struct HomeTaskDragInsertionIndicator: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor.opacity(0.72))
            .frame(height: 2)
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
    }
}

private struct HomeTaskDropDelegate: DropDelegate {
    let group: TaskGroup
    let parentID: UUID?
    let upperBeforeID: UUID?
    let lowerBeforeID: UUID?
    let rowHeight: CGFloat
    let sessionID: UUID?
    let store: TaskStore
    let coordinator: TaskDropCoordinator
    @Binding var errorMessage: String?

    func dropEntered(info: DropInfo) {
        updateTarget(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(info)
        return DropProposal(operation: acceptsDrop ? .move : .forbidden)
    }

    func dropExited(info: DropInfo) {
        guard let sessionID else { return }
        coordinator.clearTarget(sessionID: sessionID)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let sessionID,
              let sourceTask = coordinator.sourceTask,
              accepts(sourceTask: sourceTask) else {
            return false
        }
        updateTarget(info)
        guard let target = coordinator.finishDrop(sessionID: sessionID),
              let provider = info.itemProviders(for: [UTType.text]).first else {
            coordinator.clearTarget(sessionID: sessionID)
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            Task { @MainActor in
                guard let value = object as? NSString,
                      let sourceID = UUID(uuidString: value as String) else {
                    return
                }
                do {
                    try store.move(
                        id: sourceID,
                        to: target.group,
                        before: target.beforeID,
                        parentID: target.parentID
                    )
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        return true
    }

    private var acceptsDrop: Bool {
        guard let sourceTask = coordinator.sourceTask else { return true }
        return accepts(sourceTask: sourceTask)
    }

    private func accepts(sourceTask: TaskItem) -> Bool {
        if let parentID {
            return sourceTask.parentID == parentID
        }
        return sourceTask.parentID == nil
    }

    private func updateTarget(_ info: DropInfo) {
        guard let sessionID else { return }
        let target = TaskDropTarget(
            group: group,
            beforeID: info.location.y < rowHeight / 2 ? upperBeforeID : lowerBeforeID,
            parentID: parentID
        )
        guard coordinator.target != target else { return }
        coordinator.hover(
            group: target.group,
            before: target.beforeID,
            parentID: target.parentID,
            sessionID: sessionID
        )
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HomeDraggingNSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class HomeDraggingNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
