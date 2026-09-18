import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var focusStore: FocusStore
    let onOpenSettings: () -> Void
    let onFocusInteraction: () -> Void
    let onWindowReady: () -> Void

    @StateObject private var draftState = TaskDraftState()
    @State private var currentDate = Date()
    @State private var selectedSection: HomeSection = .today
    @State private var collapsedTaskIDs: Set<UUID> = []
    @State private var selectedTaskID: UUID?
    @State private var editingTaskID: UUID?
    @State private var draftFocused = false
    @State private var draftRequestID = UUID()
    @State private var errorMessage: String?
    @State private var focusPickerPresented = false
    @State private var showsOlderCompleted = false
    @StateObject private var dropCoordinator = TaskDropCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeFocusIDs: [UUID] {
        focusStore.taskIDs(at: currentDate)
    }

    private var activeFocusTasks: [TaskItem] {
        let tasksByID = Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0) })
        return activeFocusIDs.compactMap { tasksByID[$0] }
    }

    private var focusSelectableTasks: [TaskItem] {
        store.topLevelPendingTasks
    }

    private var currentFocusTask: TaskItem? {
        activeFocusTasks.first { $0.status == .pending }
    }

    private var appDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
            "MonoList"
    }

    private var todayCompletedRoots: [TaskItem] {
        store.completedTasks(on: currentDate).filter { $0.parentID == nil }
    }

    private var olderCompletedRoots: [TaskItem] {
        store.completedTasks(before: currentDate).filter { $0.parentID == nil }
    }

    var body: some View {
        Group {
            if let loadError = store.loadError {
                DataRecoveryView(
                    message: loadError.localizedDescription,
                    onRetry: { store.retryLoad() },
                    onQuit: { NSApp.terminate(nil) }
                )
            } else {
                homeContent
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

    private var homeContent: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            mainColumn
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 720, minHeight: 480)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(appDisplayName)
                    .font(.system(size: 17, weight: .semibold))
                Text(currentDate, format: .dateTime.year().month().day().weekday())
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 18)

            Divider()

            VStack(spacing: 3) {
                HomeSidebarItem(
                    title: "今天",
                    systemImage: "calendar",
                    count: nil,
                    isSelected: selectedSection == .today,
                    action: { selectSection(.today) }
                )
                HomeSidebarItem(
                    title: "进行中",
                    systemImage: "circle.dashed",
                    count: store.pendingTasks.count,
                    isSelected: selectedSection == .inProgress,
                    action: { selectSection(.inProgress) }
                )
                HomeSidebarItem(
                    title: "已完成",
                    systemImage: "checkmark.circle",
                    count: store.historyTasks.count,
                    isSelected: selectedSection == .completed,
                    action: { selectSection(.completed) }
                )
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)

            Spacer(minLength: 0)

            Divider()

            Button(action: onOpenSettings) {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 20)
                    Text("设置")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开设置")
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(width: 204)
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("今天")
                        .font(.system(size: 26, weight: .semibold))
                    Text(currentDate, format: .dateTime.month().day().weekday())
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    beginRootDraft(in: .shortTerm)
                } label: {
                    Label("新增待办", systemImage: "plus")
                }
                .buttonStyle(HomeToolbarButtonStyle())
                .help("新增待办")
            }
            .padding(.horizontal, 30)
            .padding(.top, 25)
            .padding(.bottom, 20)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        focusSection
                            .id(HomeSection.today.anchorID)
                        taskGroupSection(.shortTerm, title: "短期任务")
                            .id(HomeSection.inProgress.anchorID)
                        taskGroupSection(.longTerm, title: "长期任务")
                        completedSection
                            .id(HomeSection.completed.anchorID)
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selectedSection) { _, section in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        proxy.scrollTo(section.anchorID, anchor: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var focusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("专注")
                        .font(.system(size: 17, weight: .semibold))
                    Text(focusStatusText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加") {
                    focusPickerPresented = true
                }
                .buttonStyle(HomeInlineButtonStyle())
                .disabled(focusSelectableTasks.isEmpty && activeFocusTasks.isEmpty)
                .popover(isPresented: $focusPickerPresented, arrowEdge: .top) {
                    focusPicker
                }
                if !activeFocusTasks.isEmpty {
                    Menu {
                        Button("清空今日专注", action: clearFocusSelection)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .help("更多专注操作")
                }
            }

            if activeFocusTasks.isEmpty {
                Button {
                    focusPickerPresented = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "scope")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("还没有安排今天的专注")
                                .font(.system(size: 13, weight: .medium))
                            Text(
                                focusSelectableTasks.isEmpty
                                    ? "先添加一个待办"
                                    : "从进行中的任务中选择最多三件"
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 15)
                    .frame(minHeight: 62)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(focusSelectableTasks.isEmpty)
            } else if let currentFocusTask {
                TaskRowView(
                    item: currentFocusTask,
                    onSave: { updateText(currentFocusTask, text: $0) },
                    onComplete: { text in
                        completeTask(currentFocusTask, finalText: text)
                    },
                    onDelete: { deleteTask(currentFocusTask) },
                    onMoveUp: {},
                    onMoveDown: {},
                    onInsertAfter: {
                        beginDraft(after: currentFocusTask.id, in: currentFocusTask.group)
                    },
                    onUpdateReminder: { updateReminder(currentFocusTask, reminder: $0) },
                    onChangeGroup: { changeGroup(currentFocusTask) },
                    focusOrder: activeFocusIDs.firstIndex(of: currentFocusTask.id).map { $0 + 1 },
                    isSelected: false,
                    onSelect: {},
                    onEditingChanged: { _ in }
                )

                ForEach(
                    activeFocusTasks
                        .drop(while: { $0.id != currentFocusTask.id })
                        .dropFirst()
                ) { item in
                    if item.status == .pending {
                        TaskRowView(
                            item: item,
                            onSave: { updateText(item, text: $0) },
                            onComplete: { text in completeTask(item, finalText: text) },
                            onDelete: { deleteTask(item) },
                            onMoveUp: {},
                            onMoveDown: {},
                            onInsertAfter: {
                                beginDraft(after: item.id, in: item.group)
                            },
                            onUpdateReminder: { updateReminder(item, reminder: $0) },
                            onChangeGroup: { changeGroup(item) },
                            focusOrder: activeFocusIDs.firstIndex(of: item.id).map { $0 + 1 },
                            isSelected: false,
                            onSelect: {},
                            onEditingChanged: { _ in }
                        )
                    } else {
                        HomeCompletedTaskRow(
                            item: item,
                            onRestore: { restoreTask(item) },
                            onDelete: { deleteTask(item) },
                            indentationLevel: 0
                        )
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("今天的专注已完成")
                            .font(.system(size: 13, weight: .medium))
                        Text("其他待办仍可继续处理")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .padding(16)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    @ViewBuilder
    private func taskGroupSection(_ group: TaskGroup, title: String) -> some View {
        let roots = store.topLevelPendingTasks(in: group)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text("\(store.pendingTasks.filter { $0.group == group }.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    beginRootDraft(in: group)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("新增\(title)")
            }

            if roots.isEmpty && !(draftState.isPresented && draftState.group == group) {
                Text("还没有任务")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 7)
            }

            ForEach(Array(roots.enumerated()), id: \.element.id) { index, root in
                taskTree(
                    for: root,
                    lowerRootID: roots.indices.contains(index + 1)
                        ? roots[index + 1].id
                        : nil
                )
            }

            if draftState.isPresented,
               draftState.group == group,
               draftState.parentID == nil {
                draftRow(indentationLevel: 0)
            }
        }
    }

    @ViewBuilder
    private func taskTree(for root: TaskItem, lowerRootID: UUID?) -> some View {
        let children = store.children(of: root.id)
        VStack(alignment: .leading, spacing: 1) {
            pendingTaskRow(
                root,
                indentationLevel: 0,
                hasSubtasks: !children.isEmpty,
                dropParentID: nil,
                dropUpperBeforeID: root.id,
                dropLowerBeforeID: lowerRootID
            )
            if !collapsedTaskIDs.contains(root.id) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    if child.status == .pending {
                        pendingTaskRow(
                            child,
                            indentationLevel: 1,
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
                }
                if draftState.isPresented && draftState.parentID == root.id {
                    draftRow(indentationLevel: 1)
                }
            }
        }
    }

    private func pendingTaskRow(
        _ item: TaskItem,
        indentationLevel: Int,
        hasSubtasks: Bool,
        dropParentID: UUID?,
        dropUpperBeforeID: UUID?,
        dropLowerBeforeID: UUID?
    ) -> some View {
        return TaskRowView(
            item: item,
            onSave: { updateText(item, text: $0) },
            onComplete: { text in completeTask(item, finalText: text) },
            onDelete: { deleteTask(item) },
            onMoveUp: { moveTask(item, by: -1) },
            onMoveDown: { moveTask(item, by: 1) },
            onInsertAfter: {
                beginDraft(after: item.id, in: item.group, parentID: item.parentID)
            },
            onUpdateReminder: { updateReminder(item, reminder: $0) },
            onChangeGroup: { changeGroup(item) },
            isSelected: selectedTaskID == item.id,
            onSelect: { selectedTaskID = item.id },
            onEditingChanged: { isEditing in
                editingTaskID = isEditing ? item.id : nil
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
            subtaskProgressText: store.subtaskProgressText(for: item.id)
        )
        .overlay(alignment: .top) {
            if dropCoordinator.target == TaskDropTarget(
                group: item.group,
                beforeID: item.id,
                parentID: dropParentID
            ) {
                HomeTaskDragInsertionIndicator()
            }
        }
        .overlay(alignment: .bottom) {
            if dropLowerBeforeID == nil,
               dropCoordinator.target == TaskDropTarget(
                   group: item.group,
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
            HomeTaskDragPreview(text: item.text)
        }
        .onDrop(
            of: [UTType.text],
            delegate: HomeTaskDropDelegate(
                group: item.group,
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("已完成")
                    .font(.system(size: 17, weight: .semibold))
                Text("\(store.historyTasks.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(showsOlderCompleted ? "隐藏较早记录" : "显示较早记录") {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
                        showsOlderCompleted.toggle()
                    }
                }
                .buttonStyle(HomeInlineButtonStyle())
                .disabled(olderCompletedRoots.isEmpty)
            }

            if todayCompletedRoots.isEmpty && olderCompletedRoots.isEmpty {
                Text("完成的任务会显示在这里")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 7)
            } else {
                ForEach(todayCompletedRoots) { root in
                    completedTree(for: root)
                }
                if showsOlderCompleted {
                    ForEach(olderCompletedRoots) { root in
                        completedTree(for: root)
                    }
                }
            }
        }
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

    private var focusStatusText: String {
        guard !activeFocusTasks.isEmpty else { return "选择今天最重要的任务" }
        let completed = activeFocusTasks.filter { $0.status == .history }.count
        return "已完成 \(completed)/\(activeFocusTasks.count)"
    }

    private var focusPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("添加到今日专注")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(activeFocusIDs.count)/3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider()

            if focusSelectableTasks.isEmpty {
                Text("先添加进行中的任务")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(focusSelectableTasks) { item in
                            let order = activeFocusIDs.firstIndex(of: item.id).map { $0 + 1 }
                            Button {
                                toggleFocusMembership(item)
                            } label: {
                                HStack(spacing: 9) {
                                    if let order {
                                        Text("\(order)")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .frame(width: 20, height: 20)
                                            .background(Color.primary, in: Circle())
                                    } else {
                                        Image(systemName: "circle")
                                            .font(.system(size: 18))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 20, height: 20)
                                    }
                                    Text(item.text)
                                        .font(.system(size: 13))
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    order == nil
                                        ? Color.clear
                                        : Color.primary.opacity(0.045),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(order == nil && activeFocusIDs.count >= 3)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 300)
            }

            Divider()
            Text("选择后立即生效，最多三件")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 320)
    }

    private func selectSection(_ section: HomeSection) {
        selectedSection = section
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

    private func beginRootDraft(in group: TaskGroup) {
        commitDraft()
        let lastRoot = store.topLevelPendingTasks(in: group).last
        beginDraft(after: lastRoot?.id, in: group, parentID: nil)
    }

    private func beginSubtaskDraft(for parent: TaskItem) {
        commitDraft()
        collapsedTaskIDs.remove(parent.id)
        let lastChild = store.children(of: parent.id).last
        beginDraft(
            after: lastChild?.id,
            in: parent.group,
            parentID: parent.id
        )
    }

    private func beginDraft(after id: UUID?, in group: TaskGroup, parentID: UUID? = nil) {
        selectedTaskID = nil
        editingTaskID = nil
        draftState.present(after: id, in: group, parentID: parentID)
        draftRequestID = UUID()
        DispatchQueue.main.async {
            draftFocused = true
        }
    }

    private func draftRow(indentationLevel: Int) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Color.clear.frame(width: 20, height: 28)
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
                DispatchQueue.main.async {
                    draftFocused = true
                }
            }
            .onChange(of: draftFocused) { oldValue, newValue in
                if oldValue && !newValue {
                    commitDraft()
                }
            }
        }
        .padding(.leading, CGFloat(indentationLevel) * 21 + 8)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .id(draftRequestID)
    }

    private func indentDraft() -> Bool {
        guard draftState.parentID == nil else { return false }
        let roots = store.topLevelPendingTasks(in: draftState.group)
        guard let afterID = draftState.afterID,
              let index = roots.firstIndex(where: { $0.id == afterID }),
              index > 0 else {
            return false
        }
        let parent = roots[index - 1]
        draftState.parentID = parent.id
        draftState.afterID = store.children(of: parent.id).last?.id
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
            DispatchQueue.main.async {
                draftFocused = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateText(_ item: TaskItem, text: String) {
        performAction { try store.updateText(id: item.id, text: text) }
        if activeFocusIDs.contains(item.id) {
            onFocusInteraction()
        }
    }

    @discardableResult
    private func completeTask(_ item: TaskItem, finalText: String) -> Bool {
        let completed = performAction {
            try store.complete(id: item.id, finalText: finalText)
        }
        if activeFocusIDs.contains(item.id) {
            onFocusInteraction()
        }
        return completed
    }

    private func deleteTask(_ item: TaskItem) {
        performAction { try store.delete(id: item.id) }
        selectedTaskID = nil
        if activeFocusIDs.contains(item.id) {
            onFocusInteraction()
        }
    }

    private func restoreTask(_ item: TaskItem) {
        performAction { try store.restore(id: item.id) }
        if activeFocusIDs.contains(item.id) {
            onFocusInteraction()
        }
    }

    private func moveTask(_ item: TaskItem, by offset: Int) {
        performAction { try store.move(id: item.id, by: offset) }
    }

    private func changeGroup(_ item: TaskItem) {
        let group: TaskGroup = item.group == .shortTerm ? .longTerm : .shortTerm
        performAction { try store.move(id: item.id, to: group, before: nil) }
    }

    private func updateReminder(_ item: TaskItem, reminder: TaskReminder?) {
        performAction { try store.updateReminder(id: item.id, reminder: reminder) }
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

    private func toggleFocusMembership(_ item: TaskItem) {
        var ids = activeFocusIDs
        if let index = ids.firstIndex(of: item.id) {
            ids.remove(at: index)
        } else {
            guard ids.count < 3 else { return }
            ids.append(item.id)
        }
        do {
            if ids.isEmpty {
                try focusStore.clearSelection()
            } else {
                try focusStore.setSelection(
                    ids,
                    existingTaskIDs: Set(store.tasks.map(\.id)),
                    completedTaskIDs: Set(store.historyTasks.map(\.id)),
                    at: currentDate
                )
            }
            onFocusInteraction()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearFocusSelection() {
        performAction { try focusStore.clearSelection() }
        focusPickerPresented = false
        onFocusInteraction()
    }
}

private enum HomeSection: String {
    case today
    case inProgress
    case completed

    var anchorID: String { "home-section-\(rawValue)" }
}

private struct HomeSidebarItem: View {
    let title: String
    let systemImage: String
    let count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? .secondary : .tertiary)
                }
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                isSelected ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HomeToolbarButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(
                configuration.isPressed
                    ? Color.primary.opacity(0.11)
                    : Color.primary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
    }
}

private struct HomeInlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
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
                .help(isExpanded ? "隐藏子任务" : "展开子任务")
                .accessibilityLabel(isExpanded ? "隐藏子任务" : "展开子任务")
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

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "circle")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
            Text(text)
                .font(.system(size: 13))
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
            return sourceTask.parentID == parentID && sourceTask.group == group
        }
        return sourceTask.parentID == nil
    }

    private func updateTarget(_ info: DropInfo) {
        guard let sessionID else { return }
        let target = coordinator.dropTarget(
            group: group,
            upperBeforeID: upperBeforeID,
            lowerBeforeID: lowerBeforeID,
            locationY: info.location.y,
            rowHeight: rowHeight,
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
