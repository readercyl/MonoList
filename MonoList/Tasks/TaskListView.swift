import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TaskListView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var draftState: TaskDraftState
    let onOpenHome: () -> Void
    let onHeightChanged: (CGFloat) -> Void

    @State private var showsOlderCompleted = false
    @State private var errorMessage: String?
    @State private var selectedTaskID: UUID?
    @State private var editingTaskID: UUID?
    @State private var keyboardMonitor: Any?
    @State private var clearAction: PanelClearAction?
    @State private var currentDate = Date()
    @State private var draftFocused = false
    @State private var draftRequestID = UUID()
    @State private var collapsedTaskIDs: Set<UUID> = []
    @State private var measuredTaskContentHeight: CGFloat = 0
    @StateObject private var dropCoordinator = TaskDropCoordinator()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var todayCompletedRoots: [TaskItem] {
        store.completedTasks(on: currentDate).filter { $0.parentID == nil }
    }

    private var olderCompletedGroups: [PanelCompletedGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(
            grouping: store.completedTasks(before: currentDate).filter { $0.parentID == nil }
        ) { calendar.startOfDay(for: $0.completedAt ?? $0.updatedAt) }
        return grouped
            .map { PanelCompletedGroup(date: $0.key, tasks: $0.value) }
            .sorted { $0.date > $1.date }
    }

    private var visibleOlderCount: Int {
        showsOlderCompleted ? olderCompletedGroups.reduce(0) { $0 + $1.tasks.count } : 0
    }

    private var visiblePendingRowCount: Int {
        store.topLevelPendingTasks.reduce(0) { count, root in
            count + 1 + (
                collapsedTaskIDs.contains(root.id) ? 0 : store.children(of: root.id).count
            )
        }
    }

    private var naturalHeight: CGFloat {
        let visibleCompleted = todayCompletedRoots.count + visibleOlderCount
        let rows = store.pendingTasks.count + visibleCompleted + (draftState.isPresented ? 1 : 0)
        let visibleCompletedTasks = todayCompletedRoots + (
            showsOlderCompleted ? olderCompletedGroups.flatMap(\.tasks) : []
        )
        let extraLines = (store.pendingTasks + visibleCompletedTasks).reduce(0) {
            $0 + Self.additionalLines(for: $1.text)
        }
        let dateHeaders = showsOlderCompleted ? olderCompletedGroups.count : 0
        let estimatedHeight = Self.contentHeight(
            rowCount: rows,
            additionalLineCount: extraLines,
            dateHeaderCount: dateHeaders
        )
        let measuredHeight = measuredTaskContentHeight > 0
            ? measuredTaskContentHeight + 53
            : 0
        let minimumPendingHeight = visiblePendingRowCount > 0
            ? 150 + CGFloat(visiblePendingRowCount * 68)
            : 0
        return max(estimatedHeight, measuredHeight, minimumPendingHeight)
    }

    private var preferredHeight: CGFloat {
        min(
            max(naturalHeight, WindowCoordinator.mainPanelMinimumHeight),
            WindowCoordinator.mainPanelMaximumHeight
        )
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
                mainContent
            }
        }
        .frame(
            minWidth: WindowCoordinator.mainPanelWidth,
            idealWidth: WindowCoordinator.mainPanelWidth,
            maxWidth: WindowCoordinator.mainPanelWidth,
            minHeight: WindowCoordinator.mainPanelMinimumHeight,
            idealHeight: preferredHeight,
            maxHeight: .infinity,
            alignment: .top
        )
        .animation(nil, value: preferredHeight)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .light)
        .onAppear {
            draftState.syncVisibility(hasPendingTasks: !store.pendingTasks.isEmpty)
            installKeyboardMonitor()
            onHeightChanged(preferredHeight)
        }
        .onDisappear {
            commitDraft()
            removeKeyboardMonitor()
        }
        .onChange(of: preferredHeight) { _, height in
            onHeightChanged(height)
        }
        .onChange(of: measuredTaskContentHeight) { _, _ in
            DispatchQueue.main.async {
                onHeightChanged(preferredHeight)
            }
        }
        .onChange(of: showsOlderCompleted) { _, _ in
            DispatchQueue.main.async {
                onHeightChanged(preferredHeight)
            }
        }
        .onChange(of: store.pendingTasks.count) { _, count in
            if count == 0 && !draftState.isPresented {
                draftState.present(after: nil, in: .shortTerm)
            }
        }
        .onReceive(
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
        ) { date in
            currentDate = date
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
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.45)
            ScrollViewReader { proxy in
                ScrollView {
                    taskContent
                }
                .onPreferenceChange(PanelTaskContentHeightPreferenceKey.self) { height in
                    guard height > 0 else { return }
                    measuredTaskContentHeight = height
                }
                .onChange(of: draftRequestID) { _, _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo("panel-task-draft-row", anchor: .bottom)
                        }
                        draftFocused = true
                    }
                }
            }
            .scrollBounceBehavior(.always, axes: .vertical)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今天")
                    .font(.system(size: 15, weight: .semibold))
                Text(currentDate, format: .dateTime.month().day().weekday())
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 30)

            Button {
                clearInteraction()
                beginRootDraft()
            } label: {
                PanelHeaderIconLabel(systemName: "plus")
            }
            .buttonStyle(PanelHeaderIconButtonStyle())
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
                PanelHeaderIconLabel(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(PanelHeaderIconButtonStyle())
            .help("更多操作")

            Button {
                clearInteraction()
                onOpenHome()
            } label: {
                PanelHeaderIconLabel(systemName: "house")
            }
            .buttonStyle(PanelHeaderIconButtonStyle())
            .help("打开主页")

        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .frame(height: 52)
    }

    private var taskContent: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    beginRootDraft()
                }
                .onTapGesture {
                    clearInteraction()
                }

            VStack(alignment: .leading, spacing: 14) {
                pendingSection
                completedSection
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PanelTaskContentHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            }
        }
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("未完成")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(store.pendingTasks.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 28)

            let roots = store.topLevelPendingTasks
            if roots.isEmpty && !(draftState.isPresented && draftState.parentID == nil) {
                Text("还没有任务")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }

            ForEach(Array(roots.enumerated()), id: \.element.id) { index, root in
                taskTree(for: root, priorityRank: index < 3 ? index : nil)
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
                parentID: nil,
                upperBeforeID: root.id,
                lowerBeforeID: nil
            )

            if !collapsedTaskIDs.contains(root.id) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    if child.status == .pending {
                        pendingTaskRow(
                            child,
                            indentationLevel: 1,
                            priorityRank: nil,
                            hasSubtasks: false,
                            parentID: root.id,
                            upperBeforeID: child.id,
                            lowerBeforeID: children.indices.contains(index + 1)
                                ? children[index + 1].id
                                : nil
                        )
                    } else {
                        PanelCompletedTaskRow(
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
        parentID: UUID?,
        upperBeforeID: UUID?,
        lowerBeforeID: UUID?
    ) -> some View {
        TaskRowView(
            item: item,
            onSave: { text in performAction { try store.updateText(id: item.id, text: text) } },
            onComplete: { text in
                performAction { try store.complete(id: item.id, finalText: text) }
            },
            onDelete: {
                performAction { try store.delete(id: item.id) }
                if selectedTaskID == item.id { selectedTaskID = nil }
            },
            onMoveUp: { performAnimatedAction { try store.move(id: item.id, by: -1) } },
            onMoveDown: { performAnimatedAction { try store.move(id: item.id, by: 1) } },
            onInsertAfter: {
                beginDraft(after: item.id, parentID: item.parentID)
            },
            onUpdateReminder: { reminder in
                performAction { try store.updateReminder(id: item.id, reminder: reminder) }
            },
            isSelected: selectedTaskID == item.id,
            onSelect: { selectTask(item.id) },
            onEditingChanged: { editing in
                editingTaskID = editing ? item.id : nil
            },
            indentationLevel: indentationLevel,
            hasSubtasks: hasSubtasks,
            isExpanded: !collapsedTaskIDs.contains(item.id),
            onToggleSubtasks: { toggleSubtasks(item.id) },
            onAddSubtask: indentationLevel == 0
                ? { beginSubtaskDraft(for: item) }
                : nil,
            canAddSubtask: indentationLevel == 0,
            onIndent: {
                performHierarchyChange {
                    try store.indent(id: item.id)
                    return true
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
                parentID: parentID
            ) {
                PanelTaskDragInsertionIndicator()
            }
        }
        .overlay(alignment: .bottom) {
            if lowerBeforeID == nil,
               dropCoordinator.target == TaskDropTarget(
                   group: .shortTerm,
                   beforeID: nil,
                   parentID: parentID
               ) {
                PanelTaskDragInsertionIndicator()
            }
        }
        .onDrag {
            dropCoordinator.beginDragging(task: item)
            return NSItemProvider(object: item.id.uuidString as NSString)
        } preview: {
            PanelTaskDragPreview(text: item.text, priorityRank: priorityRank)
        }
        .onDrop(
            of: [UTType.text],
            delegate: PanelTaskDropDelegate(
                group: .shortTerm,
                parentID: parentID,
                upperBeforeID: upperBeforeID,
                lowerBeforeID: lowerBeforeID,
                rowHeight: 40,
                sessionID: dropCoordinator.sessionID,
                store: store,
                coordinator: dropCoordinator,
                errorMessage: $errorMessage
            )
        )
    }

    private var completedSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("已完成")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(store.historyTasks.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !olderCompletedGroups.isEmpty {
                    Button(showsOlderCompleted ? "隐藏" : "显示") {
                        commitDraft()
                        withAnimation(layoutAnimation) {
                            showsOlderCompleted.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .frame(width: 48, height: 24)
                    .background(Color.primary.opacity(0.055), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 31)

            if todayCompletedRoots.isEmpty && olderCompletedGroups.isEmpty {
                Text("完成的任务会显示在这里")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            } else {
                if !todayCompletedRoots.isEmpty {
                    completedDateHeader(currentDate, isToday: true)
                    ForEach(todayCompletedRoots) { item in
                        completedTree(item)
                    }
                }
                if showsOlderCompleted {
                    ForEach(olderCompletedGroups, id: \.date) { group in
                        completedDateHeader(group.date, isToday: false)
                        ForEach(group.tasks) { item in
                            completedTree(item)
                        }
                    }
                }
            }
        }
    }

    private func completedDateHeader(_ date: Date, isToday: Bool) -> some View {
        Text(isToday ? "今天" : date.formatted(.dateTime.year().month().day()))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .frame(height: 19, alignment: .center)
    }

    private func completedTree(_ item: TaskItem) -> some View {
        VStack(spacing: 1) {
            PanelCompletedTaskRow(
                item: item,
                onRestore: { restoreTask(item) },
                onDelete: { deleteTask(item) },
                indentationLevel: 0,
                hasSubtasks: !store.children(of: item.id).isEmpty,
                isExpanded: !collapsedTaskIDs.contains(item.id),
                onToggleSubtasks: { toggleSubtasks(item.id) }
            )
            if !collapsedTaskIDs.contains(item.id) {
                ForEach(store.children(of: item.id)) { child in
                    if child.status == .pending {
                        pendingTaskRow(
                            child,
                            indentationLevel: 1,
                            priorityRank: nil,
                            hasSubtasks: false,
                            parentID: item.id,
                            upperBeforeID: child.id,
                            lowerBeforeID: nil
                        )
                    } else {
                        PanelCompletedTaskRow(
                            item: child,
                            onRestore: { restoreTask(child) },
                            onDelete: { deleteTask(child) },
                            indentationLevel: 1
                        )
                    }
                }
            }
        }
    }

    private func toggleSubtasks(_ id: UUID) {
        withAnimation(layoutAnimation) {
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
        .id("panel-task-draft-row")
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

    private func clearInteraction() {
        commitDraft()
        selectedTaskID = nil
        editingTaskID = nil
        draftFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func selectTask(_ id: UUID) {
        commitDraft()
        selectedTaskID = id
        editingTaskID = nil
        draftFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
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

    private func restoreTask(_ item: TaskItem) {
        performAnimatedAction { try store.restore(id: item.id) }
    }

    private func deleteTask(_ item: TaskItem) {
        performAnimatedAction { try store.delete(id: item.id) }
        if selectedTaskID == item.id { selectedTaskID = nil }
    }

    private func performClear() {
        guard let clearAction else { return }
        performAnimatedAction {
            switch clearAction {
            case .pending: try store.clearPending()
            case .completed: try store.clearHistory()
            case .all: try store.clearAll()
            }
        }
        selectedTaskID = nil
        self.clearAction = nil
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard editingTaskID == nil, !draftFocused, let selectedTaskID else {
                return event
            }
            if event.keyCode == 51 || event.keyCode == 117 {
                self.performAnimatedAction { try self.store.delete(id: selectedTaskID) }
                self.selectedTaskID = nil
                return nil
            }
            return event
        }
    }

    private func removeKeyboardMonitor() {
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }
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

    @discardableResult
    private func performAnimatedAction(_ action: () throws -> Void) -> Bool {
        do {
            try withAnimation(layoutAnimation) { try action() }
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

    private var layoutAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    static func additionalLines(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: 235, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = font.boundingRectForFont.height
        let lineCount = max(1, Int(round(bounds.height / lineHeight)))
        return max(0, min(lineCount, 6) - 1)
    }

    static func contentHeight(
        rowCount: Int,
        additionalLineCount: Int,
        dateHeaderCount: Int
    ) -> CGFloat {
        104 +
            CGFloat(rowCount * 36) +
            CGFloat(additionalLineCount * 13) +
            CGFloat(dateHeaderCount * 19)
    }
}

private enum PanelClearAction {
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

private struct PanelCompletedGroup {
    let date: Date
    let tasks: [TaskItem]
}

private struct PanelTaskContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PanelHeaderIconLabel: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: 28, height: 28)
    }
}

private struct PanelHeaderIconButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
    }
}

private struct PanelTaskDragPreview: View {
    let text: String
    let priorityRank: Int?

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "circle")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
            Text(text)
                .font(.system(size: fontSize))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(width: 300)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
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
}

private struct PanelTaskDragInsertionIndicator: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor.opacity(0.72))
            .frame(height: 2)
            .padding(.horizontal, 8)
            .allowsHitTesting(false)
    }
}

private struct PanelCompletedTaskRow: View {
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
            if indentationLevel > 0 {
                Color.clear.frame(width: 20, height: 28)
            }
            Button(action: onRestore) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            Text(item.text)
                .font(.system(size: 13))
                .strikethrough()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .onTapGesture {
                    if hasSubtasks {
                        onToggleSubtasks()
                    }
                }
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .opacity(isHovered ? 1 : 0)
            }
            .buttonStyle(.plain)
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

private struct PanelTaskDropDelegate: DropDelegate {
    let group: TaskGroup
    let parentID: UUID?
    let upperBeforeID: UUID?
    let lowerBeforeID: UUID?
    let rowHeight: CGFloat
    let sessionID: UUID?
    let store: TaskStore
    let coordinator: TaskDropCoordinator
    @Binding var errorMessage: String?

    func dropEntered(info: DropInfo) { updateTarget(info) }

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
        if let parentID { return sourceTask.parentID == parentID }
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
