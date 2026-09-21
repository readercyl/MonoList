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

        print("Task drop coordinator smoke passed.")
    }
}
