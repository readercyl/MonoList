import Combine
import Foundation

struct TaskDropTarget: Equatable {
    let group: TaskGroup
    let beforeID: UUID?
    let highlightsGroupHeader: Bool
    let parentID: UUID?

    init(
        group: TaskGroup,
        beforeID: UUID?,
        highlightsGroupHeader: Bool = false,
        parentID: UUID? = nil
    ) {
        self.group = group
        self.beforeID = beforeID
        self.highlightsGroupHeader = highlightsGroupHeader
        self.parentID = parentID
    }
}

@MainActor
final class TaskDropCoordinator: ObservableObject {
    @Published private(set) var target: TaskDropTarget?
    @Published private(set) var sourceTask: TaskItem?
    @Published private(set) var sessionID: UUID?

    @discardableResult
    func beginDragging(task: TaskItem) -> UUID {
        let sessionID = UUID()
        self.sessionID = sessionID
        sourceTask = task
        target = nil
        return sessionID
    }

    func hover(
        group: TaskGroup,
        before destinationID: UUID?,
        highlightsGroupHeader: Bool = false,
        parentID: UUID? = nil
    ) {
        guard sessionID != nil else { return }
        target = TaskDropTarget(
            group: group,
            beforeID: destinationID,
            highlightsGroupHeader: highlightsGroupHeader,
            parentID: parentID
        )
    }

    func hover(
        group: TaskGroup,
        before destinationID: UUID?,
        highlightsGroupHeader: Bool = false,
        parentID: UUID? = nil,
        sessionID expectedSessionID: UUID
    ) {
        guard expectedSessionID == sessionID else { return }
        hover(
            group: group,
            before: destinationID,
            highlightsGroupHeader: highlightsGroupHeader,
            parentID: parentID
        )
    }

    func dropTarget(
        group: TaskGroup,
        upperBeforeID: UUID?,
        lowerBeforeID: UUID?,
        locationY: CGFloat,
        rowHeight: CGFloat,
        highlightsGroupHeader: Bool = false,
        parentID: UUID? = nil
    ) -> TaskDropTarget {
        TaskDropTarget(
            group: group,
            beforeID: locationY < rowHeight / 2 ? upperBeforeID : lowerBeforeID,
            highlightsGroupHeader: highlightsGroupHeader,
            parentID: parentID
        )
    }

    func cancel(sessionID expectedSessionID: UUID? = nil) {
        if let expectedSessionID, expectedSessionID != sessionID {
            return
        }
        target = nil
        sourceTask = nil
        sessionID = nil
    }

    func clearTarget() {
        target = nil
    }

    func clearTarget(sessionID expectedSessionID: UUID) {
        guard expectedSessionID == sessionID else { return }
        target = nil
    }

    func finishDrop() -> TaskDropTarget? {
        guard sessionID != nil, let target else { return nil }
        cancel()
        return target
    }

    func finishDrop(sessionID expectedSessionID: UUID) -> TaskDropTarget? {
        guard expectedSessionID == sessionID else { return nil }
        return finishDrop()
    }

    func performDrop(sourceID: UUID, store: TaskStore) throws {
        guard let target else { return }
        try store.move(
            id: sourceID,
            to: target.group,
            before: target.beforeID,
            parentID: target.parentID
        )
        cancel()
    }
}
