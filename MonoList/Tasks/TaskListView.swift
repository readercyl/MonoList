import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct TaskListView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var focusStore: FocusStore
    @ObservedObject var draftState: TaskDraftState
    let onClose: () -> Void
    let onOpenSettings: () -> Void
    let onFocusInteraction: () -> Void
    let onHeightChanged: (CGFloat) -> Void

    @State private var showsOlderCompleted = false
    @State private var errorMessage: String?
    @State private var selectedTaskID: UUID?
    @State private var editingTaskID: UUID?
    @State private var keyboardMonitor: Any?
    @State private var clearAction: ClearAction?
    @State private var currentDate = Date()
    @State private var draftFocused = false
    @StateObject private var dropCoordinator = TaskDropCoordinator()
    @State private var draftScrollRequest = UUID()
    @State private var taskRowHeights: [UUID: CGFloat] = [:]
    @State private var draftRowHeight: CGFloat?
    @State private var showsOtherTasks = true
    @State private var rendersOtherTasks = true
    @State private var otherTasksTransitionID = UUID()
    @State private var focusPickerPresented = false
    @State private var focusEditingText = ""
    @State private var focusEditorFocused = false
    @State private var completingTaskIDs: Set<UUID> = []
    @Namespace private var taskMovementNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        store: TaskStore,
        focusStore: FocusStore,
        draftState: TaskDraftState,
        onClose: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onFocusInteraction: @escaping () -> Void,
        onHeightChanged: @escaping (CGFloat) -> Void
    ) {
        self.store = store
        self.focusStore = focusStore
        self.draftState = draftState
        self.onClose = onClose
        self.onOpenSettings = onOpenSettings
        self.onFocusInteraction = onFocusInteraction
        self.onHeightChanged = onHeightChanged
        let startsWithOtherTasks = !focusStore.isActive()
        _showsOtherTasks = State(initialValue: startsWithOtherTasks)
        _rendersOtherTasks = State(initialValue: startsWithOtherTasks)
    }

    private var todayCompleted: [TaskItem] {
        store.completedTasks(on: currentDate)
    }

    private var olderCompleted: [TaskItem] {
        store.completedTasks(before: currentDate)
    }

    private var visibleOlderCompleted: [TaskItem] {
        showsOlderCompleted ? olderCompleted : []
    }

    private var completedGroups: [CompletedGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: visibleOlderCompleted) {
            calendar.startOfDay(for: $0.completedAt ?? .distantPast)
        }
        return grouped
            .map { CompletedGroup(date: $0.key, tasks: $0.value) }
            .sorted { $0.date > $1.date }
    }

    private var activeFocusIDs: [UUID] {
        focusStore.taskIDs(at: currentDate)
    }

    private var activeFocusTasks: [TaskItem] {
        let tasksByID = Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0) })
        return activeFocusIDs.compactMap { tasksByID[$0] }
    }

    private var pendingFocusTasks: [TaskItem] {
        activeFocusTasks.filter { $0.status == .pending }
    }

    private var lockedFocusTasks: [TaskItem] {
        activeFocusTasks.filter { $0.status == .history }
    }

    private var currentFocusTask: TaskItem? {
        activeFocusTasks.first { $0.status == .pending }
    }

    private var focusSelectableTasks: [TaskItem] {
        store.shortTermTasks + store.longTermTasks
    }

    private var otherPendingTasks: [TaskItem] {
        store.pendingTasks.filter { !activeFocusIDs.contains($0.id) }
    }

    private var hasActiveFocus: Bool {
        focusStore.isActive(at: currentDate)
    }

    private var naturalHeight: CGFloat {
        let extraLines = (todayCompleted + visibleOlderCompleted).reduce(0) {
            $0 + Self.additionalLines(for: $1.text)
        }
        let draftAdditionalHeight: CGFloat
        if draftState.isPresented, let draftRowHeight {
            draftAdditionalHeight = max(0, draftRowHeight - 36)
        } else if draftState.isPresented {
            draftAdditionalHeight = CGFloat(
                Self.additionalLines(for: draftState.text) * 13
            )
        } else {
            draftAdditionalHeight = 0
        }
        let pendingAdditionalHeight = otherPendingTasks.reduce(CGFloat.zero) {
            height, item in
            if let measuredHeight = taskRowHeights[item.id] {
                return height + max(0, measuredHeight - 36)
            }
            let addedRows = Self.additionalLines(for: item.text) +
                (item.reminder == nil ? 0 : 1)
            return height + CGFloat(addedRows * 17)
        }
        let rows = otherPendingTasks.count +
            todayCompleted.count +
            visibleOlderCompleted.count +
            (draftState.isPresented ? 1 : 0)
        let dateHeaders = showsOlderCompleted ? completedGroups.count : 0
        let otherContentHeight = Self.contentHeight(
            rowCount: rows,
            additionalLineCount: extraLines,
            dateHeaderCount: dateHeaders
        ) + pendingAdditionalHeight
        let focusHeight = hasActiveFocus
            ? Self.focusSectionHeight(for: activeFocusTasks) + 40
            : 61
        return otherContentHeight + draftAdditionalHeight + focusHeight + 58
    }

    private var preferredHeight: CGFloat {
        if hasActiveFocus && !showsOtherTasks {
            let editingHeight: CGFloat = editingTaskID == nil ? 0 : 54
            return min(Self.focusContentHeight(
                for: activeFocusTasks
            ) + editingHeight, WindowCoordinator.mainPanelMaximumHeight)
        }
        return min(
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
        .animation(layoutAnimation, value: activeFocusIDs)
        .animation(layoutAnimation, value: otherPendingTasks.map(\.id))
        .animation(layoutAnimation, value: pendingFocusTasks.map(\.id))
        .animation(layoutAnimation, value: todayCompleted.map(\.id))
        .animation(layoutAnimation, value: showsOlderCompleted)
        .animation(layoutAnimation, value: draftState.isPresented)
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
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .light)
        .onAppear {
            focusStore.reconcile(existingTaskIDs: Set(store.tasks.map(\.id)))
            setOtherTasksExpanded(
                !focusStore.isActive(at: currentDate),
                animated: false
            )
            draftState.syncVisibility(hasPendingTasks: !store.pendingTasks.isEmpty)
            installKeyboardMonitor()
            onHeightChanged(preferredHeight)
        }
        .onDisappear {
            otherTasksTransitionID = UUID()
            commitDraft()
            removeKeyboardMonitor()
        }
        .onChange(of: preferredHeight) { _, height in
            onHeightChanged(height)
        }
        .onChange(of: store.pendingTasks.count) { _, count in
            if count == 0 && !draftState.isPresented {
                draftState.present(after: nil)
            }
        }
        .onChange(of: store.tasks) { _, tasks in
            focusStore.reconcile(existingTaskIDs: Set(tasks.map(\.id)))
            if !focusStore.isActive(at: currentDate) {
                setOtherTasksExpanded(true, animated: false)
            }
        }
        .onReceive(
            Timer.publish(every: 60, on: .main, in: .common).autoconnect()
        ) { date in
            currentDate = date
            if !focusStore.isActive(at: date) {
                setOtherTasksExpanded(true, animated: false)
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
            Button("取消", role: .cancel) {
                clearAction = nil
            }
        } message: {
            Text(clearAction?.message ?? "")
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        mainList
    }

    private var mainList: some View {
        VStack(spacing: 0) {
            standardListHeader
            Divider().opacity(0.45)
            ScrollViewReader { proxy in
                ScrollView {
                    scrollableTaskContent
                }
                .onChange(of: draftScrollRequest) { _, _ in
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo("task-draft-row", anchor: .bottom)
                        }
                        DispatchQueue.main.async { draftFocused = true }
                    }
                }
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollDisabled(false)
        }
    }

    private var scrollableTaskContent: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                focusSection
                focusPickerAnchor
            }
            if hasActiveFocus {
                Divider().opacity(0.45)
                otherTasksDisclosure
                    .transition(.opacity)
            }
            if !hasActiveFocus || rendersOtherTasks {
                Divider().opacity(0.35)
                otherTaskContent
            }
        }
    }

    private var focusPickerAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .offset(x: -12, y: 20)
            .popover(isPresented: $focusPickerPresented, arrowEdge: .trailing) {
                focusPicker
            }
            .accessibilityHidden(true)
    }

    private var otherTaskContent: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    focusDraft(after: tasks(in: .shortTerm).last?.id)
                }
                .onTapGesture {
                    clearFocus()
                }

            VStack(spacing: 0) {
                taskGroupSection(.shortTerm, title: "短期任务")
                taskGroupSection(.longTerm, title: "长期任务")
                completedSection
            }
            .padding(.horizontal, 7)
            .padding(.top, 7)
            .padding(.bottom, 7)
            .frame(maxWidth: .infinity, alignment: .top)
            .onPreferenceChange(TaskRowHeightPreferenceKey.self) { heights in
                taskRowHeights = heights
            }
            .onPreferenceChange(DraftRowHeightPreferenceKey.self) { height in
                draftRowHeight = height
            }
        }
    }

    private var standardListHeader: some View {
        HStack(spacing: 7) {
            Text("今天")
                .font(.system(size: 17, weight: .semibold))
            Text(currentDate, format: .dateTime.month().day().weekday())
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            WindowDragArea()
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        clearFocus()
                    }
                )

            Button {
                commitDraft()
                setOtherTasksExpanded(true, animated: false)
                focusDraft(after: tasks(in: .shortTerm).last?.id)
            } label: {
                HeaderIconLabel(systemName: "plus")
            }
            .buttonStyle(HeaderIconButtonStyle())
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
                HeaderIconLabel(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(HeaderIconButtonStyle())
            .frame(width: 30, height: 30)
            .simultaneousGesture(
                TapGesture().onEnded {
                    commitDraft()
                }
            )
            .help("更多操作")

            Button {
                commitDraft()
                onOpenSettings()
            } label: {
                HeaderIconLabel(systemName: "gearshape")
            }
            .buttonStyle(HeaderIconButtonStyle())
            .help("打开控制台")
        }
        .padding(.leading, 14)
        .padding(.trailing, 9)
        .frame(height: 54)
    }

    @ViewBuilder
    private var focusSection: some View {
        if hasActiveFocus {
            activeFocusSection
                .transition(.opacity)
        } else {
            emptyFocusSection
                .transition(.opacity)
        }
    }

    private var emptyFocusSection: some View {
        Button {
            focusPickerPresented = true
        } label: {
            HStack(spacing: 9) {
                Text("1")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 21, height: 21)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 6))
                Text("今天先做什么？")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(focusSelectableTasks.isEmpty ? "先添加待办" : "添加专注任务 ›")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: 43)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(focusSelectableTasks.isEmpty)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private var activeFocusSection: some View {
        VStack(spacing: 0) {
            focusZoneHeader
            focusTaskContent
        }
    }

    private var focusZoneHeader: some View {
        let progress = currentFocusTask.flatMap { item in
            activeFocusTasks.firstIndex(where: { $0.id == item.id }).map { $0 + 1 }
        } ?? activeFocusTasks.count
        let allCompleted = !activeFocusTasks.isEmpty && currentFocusTask == nil
        return HStack(spacing: 7) {
            Text(allCompleted ? "今日完成" : "今日专注")
                .font(.system(size: 12, weight: .semibold))
            Text("\(progress)/\(activeFocusTasks.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("＋ 添加") {
                commitFocusEditingIfNeeded()
                focusPickerPresented = true
            }
            .buttonStyle(FocusInlineButtonStyle())
            Menu {
                Button("清空今日专注") {
                    clearFocusSelection()
                }
            } label: {
                HeaderIconLabel(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(HeaderIconButtonStyle())
            .frame(width: 30, height: 30)
            .help("更多操作")
            .accessibilityLabel("更多操作")
        }
        .padding(.leading, 17)
        .padding(.trailing, 12)
        .frame(height: 39)
    }

    private var focusTaskContent: some View {
        VStack(spacing: 0) {
            if let currentFocusTask {
                HStack(alignment: .center, spacing: 13) {
                    TaskCompletionButton(
                        symbolSize: 24,
                        frameSize: 26,
                        isCompleting: completingTaskIDs.contains(currentFocusTask.id),
                        action: { completeFocusTask(currentFocusTask) }
                    )
                    VStack(alignment: .leading, spacing: 7) {
                        Text("当前")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        focusEditableText(
                            for: currentFocusTask,
                            fontSize: 19,
                            fontWeight: .semibold,
                            editorFontWeight: .semibold,
                            lineLimit: 3,
                            lineSpacing: 2
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 13)
                .padding(.bottom, 19)
                .matchedGeometryEffect(
                    id: currentFocusTask.id,
                    in: taskMovementNamespace
                )
                .transition(.opacity)
                .contextMenu {
                    Button("删除", role: .destructive) {
                        deleteFocusTask(currentFocusTask)
                    }
                }
                if pendingFocusTasks.count > 1 {
                    Divider().opacity(0.45)
                    Text("接下来")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 57)
                        .padding(.top, 12)
                        .padding(.bottom, 3)
                    ForEach(pendingFocusTasks.dropFirst()) { item in
                        focusFollowingRow(item)
                    }
                }
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .medium))
                    Text("今天的专注已完成")
                        .font(.system(size: 16, weight: .semibold))
                    Text("其他待办仍可继续处理")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 112)
                .transition(.opacity)
            }
        }
    }

    private func focusFollowingRow(_ item: TaskItem) -> some View {
        return HStack(alignment: .center, spacing: 10) {
            TaskCompletionButton(
                symbolSize: 19,
                frameSize: 24,
                isCompleting: completingTaskIDs.contains(item.id),
                action: { completeFocusTask(item) }
            )
            focusEditableText(
                for: item,
                fontSize: 14,
                fontWeight: .regular,
                editorFontWeight: .regular,
                lineLimit: 2,
                lineSpacing: 1
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .frame(minHeight: 47)
        .matchedGeometryEffect(id: item.id, in: taskMovementNamespace)
        .transition(.opacity)
        .contentShape(Rectangle())
        .contextMenu {
            Button("删除", role: .destructive) {
                deleteFocusTask(item)
            }
        }
    }

    @ViewBuilder
    private func focusEditableText(
        for item: TaskItem,
        fontSize: CGFloat,
        fontWeight: Font.Weight,
        editorFontWeight: NSFont.Weight,
        lineLimit: Int,
        lineSpacing: CGFloat
    ) -> some View {
        if editingTaskID == item.id {
            TaskTextEditor(
                text: $focusEditingText,
                isFocused: $focusEditorFocused,
                fontSize: fontSize,
                fontWeight: editorFontWeight,
                onSubmit: { finishFocusEditing(item) }
            )
            .onAppear {
                DispatchQueue.main.async {
                    focusEditorFocused = true
                }
            }
            .onChange(of: focusEditorFocused) { oldValue, newValue in
                if oldValue && !newValue {
                    finishFocusEditing(item)
                }
            }
        } else {
            Text(item.text)
                .font(.system(size: fontSize, weight: fontWeight))
                .strikethrough(completingTaskIDs.contains(item.id))
                .foregroundStyle(
                    completingTaskIDs.contains(item.id) ? .secondary : .primary
                )
                .opacity(completingTaskIDs.contains(item.id) ? 0.66 : 1)
                .lineLimit(lineLimit)
                .lineSpacing(lineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    TapGesture(count: 2).onEnded {
                        beginFocusEditing(item)
                    }
                )
                .accessibilityHint("双击修改任务")
        }
    }

    private var otherTasksDisclosure: some View {
        Button {
            setOtherTasksExpanded(!showsOtherTasks)
        } label: {
            HStack(spacing: 7) {
                Text("其他待办")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(otherPendingTasks.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(showsOtherTasks ? 90 : 0))
                    .animation(feedbackAnimation, value: showsOtherTasks)
            }
            .padding(.horizontal, 17)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsOtherTasks ? "收起其他待办" : "展开其他待办")
    }

    private func setOtherTasksExpanded(
        _ expanded: Bool,
        animated: Bool = true
    ) {
        let transitionID = UUID()
        otherTasksTransitionID = transitionID

        if expanded {
            rendersOtherTasks = true
            showsOtherTasks = true
            return
        }

        showsOtherTasks = false
        guard animated && !reduceMotion else {
            rendersOtherTasks = false
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard otherTasksTransitionID == transitionID,
                  !showsOtherTasks else {
                return
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                rendersOtherTasks = false
            }
        }
    }

    private var focusPicker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("添加到今日专注")
                    .font(.system(size: 12, weight: .semibold))
                Text("\(activeFocusIDs.count)/3")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    focusPickerPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 8)
            .frame(height: 38)

            Divider().opacity(0.4)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(lockedFocusTasks) { item in
                        focusPickerLockedRow(item)
                    }
                    ForEach(focusSelectableTasks) { item in
                        focusPickerRow(item)
                    }
                }
                .padding(7)
            }
            .frame(maxHeight: 290)

            Divider().opacity(0.4)
            Text("选择后立即生效；最多三件")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 34)
        }
        .frame(width: 286)
        .animation(feedbackAnimation, value: activeFocusIDs)
    }

    private func focusPickerRow(_ item: TaskItem) -> some View {
        let order = activeFocusIDs.firstIndex(of: item.id).map { $0 + 1 }
        let canToggle = order != nil || activeFocusIDs.count < 3
        return Button {
            toggleFocusMembership(item)
        } label: {
            HStack(alignment: .center, spacing: 9) {
                Group {
                    if let order {
                        Text("\(order)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color.primary, in: Circle())
                    } else {
                        Image(systemName: "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(canToggle ? .secondary : .tertiary)
                            .frame(width: 20, height: 20)
                    }
                }
                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(canToggle ? .primary : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                order == nil ? Color.clear : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canToggle)
        .accessibilityLabel(
            "\(item.text)\(order.map { "，专注第 \($0) 项" } ?? "，未选择")"
        )
    }

    private func focusPickerLockedRow(_ item: TaskItem) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.system(size: 12))
                    .strikethrough()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text("已完成 · 当天保留")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
    }

    private func tasks(in group: TaskGroup) -> [TaskItem] {
        let groupTasks = group == .shortTerm ? store.shortTermTasks : store.longTermTasks
        return groupTasks.filter { !activeFocusIDs.contains($0.id) }
    }

    @ViewBuilder
    private func taskGroupSection(_ group: TaskGroup, title: String) -> some View {
        let groupTasks = tasks(in: group)
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(groupTasks.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 29)
        .contentShape(Rectangle())
        .background(
            dropCoordinator.target?.group == group &&
                dropCoordinator.target?.highlightsGroupHeader == true
                ? Color.accentColor.opacity(0.08)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .onDrop(of: [UTType.text], delegate: TaskGroupDropDelegate(
            group: group,
            upperBeforeID: nil,
            lowerBeforeID: nil,
            rowHeight: 29,
            highlightsGroupHeader: true,
            sessionID: dropCoordinator.sessionID,
            store: store,
            coordinator: dropCoordinator,
            errorMessage: $errorMessage
        ))

        ForEach(Array(groupTasks.enumerated()), id: \.element.id) { index, item in
            TaskRowView(
                item: item,
                onSave: { text in
                    performAction { try store.updateText(id: item.id, text: text) }
                    if activeFocusIDs.contains(item.id) { onFocusInteraction() }
                },
                onComplete: { text in
                    let completed = performAnimatedAction {
                        try store.complete(id: item.id, finalText: text)
                    }
                    if activeFocusIDs.contains(item.id) { onFocusInteraction() }
                    return completed
                },
                onDelete: {
                    performAnimatedAction { try store.delete(id: item.id) }
                    if activeFocusIDs.contains(item.id) { onFocusInteraction() }
                    if selectedTaskID == item.id {
                        selectedTaskID = nil
                    }
                },
                onMoveUp: performAnimated { try store.move(id: item.id, by: -1) },
                onMoveDown: performAnimated { try store.move(id: item.id, by: 1) },
                onInsertAfter: {
                    focusDraft(after: item.id, in: item.group)
                },
                onUpdateReminder: perform { reminder in
                    try store.updateReminder(id: item.id, reminder: reminder)
                },
                onChangeGroup: performAnimated {
                    try store.move(
                        id: item.id,
                        to: item.group == .shortTerm ? .longTerm : .shortTerm,
                        before: nil
                    )
                },
                focusOrder: nil,
                isSelected: selectedTaskID == item.id,
                onSelect: { selectTask(item.id) },
                onEditingChanged: { editing in
                    editingTaskID = editing ? item.id : nil
                }
            )
            .matchedGeometryEffect(id: item.id, in: taskMovementNamespace)
            .transition(.opacity)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TaskRowHeightPreferenceKey.self,
                        value: [item.id: proxy.size.height]
                    )
                }
            }
            .overlay(alignment: .top) {
                if dropCoordinator.target == TaskDropTarget(
                    group: group,
                    beforeID: item.id
                ) {
                    TaskDragInsertionIndicator()
                }
            }
            .overlay(alignment: .bottom) {
                if index == groupTasks.count - 1,
                   dropCoordinator.target == TaskDropTarget(
                       group: group,
                       beforeID: nil
                   ) {
                    TaskDragInsertionIndicator()
                }
            }
            .onDrag {
                dropCoordinator.beginDragging(task: item)
                return NSItemProvider(object: item.id.uuidString as NSString)
            } preview: {
                TaskDragPreview(text: item.text)
            }
            .onDrop(
                of: [UTType.text],
                delegate: TaskGroupDropDelegate(
                    group: group,
                    upperBeforeID: item.id,
                    lowerBeforeID: groupTasks.indices.contains(index + 1)
                        ? groupTasks[index + 1].id
                        : nil,
                    rowHeight: taskRowHeights[item.id] ?? 36,
                    highlightsGroupHeader: false,
                    sessionID: dropCoordinator.sessionID,
                    store: store,
                    coordinator: dropCoordinator,
                    errorMessage: $errorMessage
                )
            )

            if draftState.isPresented && draftState.afterID == item.id {
                draftDropRow(
                    group: group,
                    beforeID: groupTasks.indices.contains(index + 1)
                        ? groupTasks[index + 1].id
                        : nil
                )
            }
        }
        if draftState.isPresented && draftState.group == group && draftState.afterID == nil {
            draftDropRow(group: group, beforeID: nil)
        }
    }

    private func draftDropRow(group: TaskGroup, beforeID: UUID?) -> some View {
        draftRow
            .id("task-draft-row")
            .transition(.opacity)
            .onDrop(
                of: [UTType.text],
                delegate: TaskGroupDropDelegate(
                    group: group,
                    upperBeforeID: beforeID,
                    lowerBeforeID: beforeID,
                    rowHeight: 36,
                    highlightsGroupHeader: false,
                    sessionID: dropCoordinator.sessionID,
                    store: store,
                    coordinator: dropCoordinator,
                    errorMessage: $errorMessage
                )
            )
    }

    private var draftRow: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "circle")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
                .frame(width: 28, height: 28)
            TaskTextEditor(
                text: $draftState.text,
                isFocused: $draftFocused,
                onSubmit: continueDraft
            )
                .onAppear {
                    if !store.pendingTasks.isEmpty {
                        DispatchQueue.main.async {
                            draftFocused = true
                        }
                    }
                }
                .onChange(of: draftFocused) { oldValue, newValue in
                    if oldValue && !newValue {
                        commitDraft()
                    }
                }
                .padding(.vertical, 5)
            Color.clear.frame(width: 28, height: 28)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DraftRowHeightPreferenceKey.self,
                    value: proxy.size.height
                )
            }
        }
    }

    private var completedSection: some View {
        VStack(spacing: 2) {
            HStack {
                Text("已完成")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
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
            .padding(.horizontal, 10)
            .frame(height: 35)

            ForEach(todayCompleted) { item in
                completedRow(item)
            }

            if showsOlderCompleted {
                ForEach(completedGroups, id: \.date) { group in
                    Text(group.date, format: .dateTime.year().month().day())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 19)
                    ForEach(group.tasks) { item in
                        completedRow(item)
                    }
                }
            }
        }
    }

    private func completedRow(_ item: TaskItem) -> some View {
        CompletedTaskRow(
            item: item,
            onRestore: {
                performAnimatedAction { try store.restore(id: item.id) }
                if activeFocusIDs.contains(item.id) { onFocusInteraction() }
            },
            onDelete: {
                performAnimatedAction { try store.delete(id: item.id) }
                if activeFocusIDs.contains(item.id) { onFocusInteraction() }
            }
        )
        .matchedGeometryEffect(id: item.id, in: taskMovementNamespace)
        .transition(.opacity)
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
                focusPickerPresented = false
                setOtherTasksExpanded(true, animated: false)
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
        do {
            commitFocusEditingIfNeeded()
            try focusStore.clearSelection()
            focusPickerPresented = false
            focusEditorFocused = false
            focusEditingText = ""
            editingTaskID = nil
            setOtherTasksExpanded(true, animated: false)
            onFocusInteraction()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func completeFocusTask(_ item: TaskItem) {
        guard !completingTaskIDs.contains(item.id) else { return }
        if editingTaskID == item.id {
            finishFocusEditing(item)
        }
        withAnimation(feedbackAnimation) {
            _ = completingTaskIDs.insert(item.id)
        }
        let delay = reduceMotion ? 0 : 0.24
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            performAnimatedAction { try store.complete(id: item.id) }
            completingTaskIDs.remove(item.id)
            onFocusInteraction()
        }
    }

    private func beginFocusEditing(_ item: TaskItem) {
        if let editingTaskID,
           let editingItem = activeFocusTasks.first(where: { $0.id == editingTaskID }) {
            finishFocusEditing(editingItem)
        }
        focusEditingText = item.text
        editingTaskID = item.id
        DispatchQueue.main.async {
            focusEditorFocused = true
        }
    }

    private func finishFocusEditing(_ item: TaskItem) {
        guard editingTaskID == item.id else { return }
        let normalized = focusEditingText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty && focusEditingText != item.text {
            performAction { try store.updateText(id: item.id, text: focusEditingText) }
            onFocusInteraction()
        }
        focusEditingText = ""
        focusEditorFocused = false
        editingTaskID = nil
    }

    private func commitFocusEditingIfNeeded() {
        guard let editingTaskID,
              let item = activeFocusTasks.first(where: { $0.id == editingTaskID }) else {
            return
        }
        finishFocusEditing(item)
    }

    private func deleteFocusTask(_ item: TaskItem) {
        if editingTaskID == item.id {
            finishFocusEditing(item)
        }
        performAnimatedAction { try store.delete(id: item.id) }
        onFocusInteraction()
    }

    private func clearFocus() {
        commitDraft()
        selectedTaskID = nil
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
            draftRowHeight = nil
            selectedTaskID = nil
            editingTaskID = nil
            draftScrollRequest = UUID()
            DispatchQueue.main.async {
                draftFocused = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectTask(_ id: UUID) {
        commitDraft()
        selectedTaskID = id
        editingTaskID = nil
        draftFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func focusDraft(after id: UUID?, in group: TaskGroup = .shortTerm) {
        selectedTaskID = nil
        editingTaskID = nil
        draftRowHeight = nil
        draftState.present(after: id, in: group)
        draftScrollRequest = UUID()
        DispatchQueue.main.async {
            selectedTaskID = nil
            editingTaskID = nil
            draftFocused = true
        }
    }

    static func additionalLines(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(
                width: 235,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = font.boundingRectForFont.height
        let lineCount = max(1, Int(round(bounds.height / lineHeight)))
        return max(0, min(lineCount, 6) - 1)
    }

    static func focusContentHeight(for tasks: [TaskItem]) -> CGFloat {
        let height = 54 + focusSectionHeight(for: tasks) + 40
        return min(
            max(ceil(height), WindowCoordinator.mainPanelMinimumHeight),
            WindowCoordinator.mainPanelMaximumHeight
        )
    }

    private static func focusSectionHeight(for tasks: [TaskItem]) -> CGFloat {
        let pendingTasks = tasks.filter { $0.status == .pending }
        guard let currentTask = pendingTasks.first else {
            return 151
        }

        let currentExtraLines = focusAdditionalLines(
            for: currentTask.text,
            fontSize: 19,
            width: 241,
            limit: 3
        )
        let followingTasks = Array(pendingTasks.dropFirst().prefix(2))
        let followingExtraHeight = followingTasks.reduce(CGFloat.zero) { height, task in
            let extraLines = focusAdditionalLines(
                for: task.text,
                fontSize: 14,
                width: 248,
                limit: 2
            )
            return height + 47 + CGFloat(extraLines * 20)
        }
        let followingSectionHeight: CGFloat = followingTasks.isEmpty
            ? 0
            : 31 + followingExtraHeight
        let height = 122 +
            CGFloat(currentExtraLines * 27) +
            followingSectionHeight
        return ceil(height)
    }

    private static func focusAdditionalLines(
        for text: String,
        fontSize: CGFloat,
        width: CGFloat,
        limit: Int
    ) -> Int {
        guard !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lineHeight = font.boundingRectForFont.height
        let lineCount = max(1, Int(ceil(bounds.height / lineHeight)))
        return max(0, min(lineCount, limit) - 1)
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

    private func performClear() {
        guard let clearAction else { return }
        performAnimatedAction {
            switch clearAction {
            case .pending:
                try store.clearPending()
            case .completed:
                try store.clearHistory()
            case .all:
                try store.clearAll()
            }
        }
        selectedTaskID = nil
        self.clearAction = nil
    }

    private func performAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func performAnimatedAction(_ action: () throws -> Void) -> Bool {
        do {
            try withAnimation(layoutAnimation) {
                try action()
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private var feedbackAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }

    private var layoutAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.22)
    }

    private func perform(_ action: @escaping () throws -> Void) -> () -> Void {
        { performAction(action) }
    }

    private func perform<Value>(
        _ action: @escaping (Value) throws -> Void
    ) -> (Value) -> Void {
        { value in performAction { try action(value) } }
    }

    private func performAnimated(
        _ action: @escaping () throws -> Void
    ) -> () -> Void {
        { _ = performAnimatedAction(action) }
    }
}

private struct FocusInlineButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                configuration.isPressed ? Color.primary.opacity(0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
    }
}

private struct HeaderIconLabel: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
    }
}

private struct TaskDragPreview: View {
    let text: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "circle")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
            Text(text)
                .font(.system(size: 13))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 28, height: 28)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(width: 300)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
    }
}

private struct TaskDragInsertionIndicator: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor.opacity(0.72))
            .frame(height: 2)
        .padding(.horizontal, 8)
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

private struct TaskRowHeightPreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(
        value: inout [UUID: CGFloat],
        nextValue: () -> [UUID: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct DraftRowHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat? = nil

    static func reduce(
        value: inout CGFloat?,
        nextValue: () -> CGFloat?
    ) {
        value = nextValue()
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DraggingNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class DraggingNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct HeaderIconButtonStyle: ButtonStyle {
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

private struct CompletedGroup {
    let date: Date
    let tasks: [TaskItem]
}

private struct CompletedTaskRow: View {
    let item: TaskItem
    let onRestore: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Button(action: onRestore) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            Text(item.text)
                .strikethrough()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .opacity(isHovered ? 1 : 0)
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.16),
                        value: isHovered
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("恢复为未完成", action: onRestore)
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}

private enum ClearAction {
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

    var message: String {
        "此操作会立即永久删除对应任务，且无法撤销。"
    }
}

private struct TaskGroupDropDelegate: DropDelegate {
    let group: TaskGroup
    let upperBeforeID: UUID?
    let lowerBeforeID: UUID?
    let rowHeight: CGFloat
    let highlightsGroupHeader: Bool
    let sessionID: UUID?
    let store: TaskStore
    let coordinator: TaskDropCoordinator
    @Binding var errorMessage: String?

    func dropEntered(info: DropInfo) {
        updateTarget(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard let sessionID else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            coordinator.clearTarget(sessionID: sessionID)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let sessionID else { return false }
        updateTarget(info)
        guard let target = coordinator.finishDrop(sessionID: sessionID) else {
            coordinator.clearTarget(sessionID: sessionID)
            return false
        }
        guard let provider = info.itemProviders(for: [UTType.text]).first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            Task { @MainActor in
                guard let value = object as? NSString,
                      let sourceID = UUID(uuidString: value as String) else {
                    return
                }
                do {
                    try withAnimation(
                        .easeOut(duration: 0.16)
                    ) {
                        try store.move(
                            id: sourceID,
                            to: target.group,
                            before: target.beforeID
                        )
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
        return true
    }

    private func updateTarget(_ info: DropInfo) {
        guard let sessionID else { return }
        let target = coordinator.dropTarget(
            group: group,
            upperBeforeID: upperBeforeID,
            lowerBeforeID: lowerBeforeID,
            locationY: info.location.y,
            rowHeight: rowHeight,
            highlightsGroupHeader: highlightsGroupHeader
        )
        guard coordinator.target != target else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            coordinator.hover(
                group: target.group,
                before: target.beforeID,
                highlightsGroupHeader: target.highlightsGroupHeader,
                sessionID: sessionID
            )
        }
    }
}
