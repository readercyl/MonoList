import Foundation

@main
struct TaskDropCoordinatorSmoke {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListTaskDropTests-\(UUID().uuidString)")
        let store = TaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        let first = try store.add(text: "第一条")
        let second = try store.add(text: "第二条")
        let third = try store.add(text: "第三条")
        let coordinator = TaskDropCoordinator()

        let session = coordinator.beginDragging(task: first)
        coordinator.hover(
            group: .shortTerm,
            before: third.id,
            sessionID: session
        )
        try coordinator.performDrop(sourceID: first.id, store: store)
        precondition(store.pendingTasks.map(\.id) == [second.id, first.id, third.id])
        precondition(coordinator.sessionID == nil)

        let child = try store.add(text: "子任务", parentID: second.id)
        let childSession = coordinator.beginDragging(task: child)
        coordinator.hover(
            group: .shortTerm,
            before: nil,
            parentID: second.id,
            sessionID: childSession
        )
        try coordinator.performDrop(sourceID: child.id, store: store)
        precondition(store.children(of: second.id).map(\.id) == [child.id])

        // Every row boundary must have one owner; only the last sibling targets the end.
        precondition(store.nextPendingSiblingID(after: second) == first.id)
        precondition(store.nextPendingSiblingID(after: first) == third.id)
        precondition(store.nextPendingSiblingID(after: third) == nil)
        let tallRowTarget = coordinator.dropTarget(
            group: .shortTerm, upperBeforeID: second.id, lowerBeforeID: first.id,
            locationY: 45, rowHeight: 120
        )
        precondition(tallRowTarget.beforeID == second.id)
        precondition(store.pendingSequenceNumber(for: second) == 1)
        precondition(store.pendingSequenceNumber(for: first) == 2)
        precondition(store.pendingSequenceNumber(for: child) == 1)
        let anotherChild = try store.add(text: "另一子任务", parentID: second.id)
        precondition(store.pendingSequenceNumber(for: anotherChild) == 2)
        try store.complete(id: child.id)
        precondition(store.pendingSequenceNumber(for: anotherChild) == 1)
        try store.restore(id: child.id)
        precondition(store.children(of: second.id).filter { $0.status == .pending }
            .enumerated().allSatisfy { store.pendingSequenceNumber(for: $0.element) == $0.offset + 1 })
        let upwardSession = coordinator.beginDragging(task: third)
        coordinator.hover(group: .shortTerm, before: second.id, sessionID: upwardSession)
        try coordinator.performDrop(sourceID: third.id, store: store)
        precondition(store.topLevelPendingTasks.map(\.id) == [third.id, second.id, first.id])
        let downwardSession = coordinator.beginDragging(task: third)
        coordinator.hover(group: .shortTerm,
                          before: store.nextPendingSiblingID(after: second),
                          sessionID: downwardSession)
        try coordinator.performDrop(sourceID: third.id, store: store)
        precondition(store.topLevelPendingTasks.map(\.id) == [second.id, third.id, first.id])
        let moveChildSession = coordinator.beginDragging(task: anotherChild)
        coordinator.hover(group: .shortTerm, before: child.id,
                          parentID: second.id, sessionID: moveChildSession)
        try coordinator.performDrop(sourceID: anotherChild.id, store: store)
        precondition(store.pendingSequenceNumber(for: anotherChild) == 1)
        precondition(store.pendingSequenceNumber(for: child) == 2)
        try store.complete(id: third.id)
        precondition(store.pendingSequenceNumber(for: first) == 2)
        let reloaded = TaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        precondition(reloaded.pendingTasks.map(\.id) == store.pendingTasks.map(\.id))
        precondition(reloaded.tasks.first { $0.id == first.id }?.text == "第一条")
        print("Task drop coordinator smoke passed.")
    }
}
