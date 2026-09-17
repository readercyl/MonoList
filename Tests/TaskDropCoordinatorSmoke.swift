import Foundation

@main
struct TaskDropCoordinatorSmoke {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MonoListDropTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = TaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        let short = try store.add(text: "短期")
        let long = try store.add(text: "长期", group: .longTerm)
        let coordinator = TaskDropCoordinator()

        coordinator.beginDragging(task: short)
        coordinator.hover(
            group: .shortTerm,
            before: nil,
            highlightsGroupHeader: true
        )
        precondition(coordinator.target?.highlightsGroupHeader == true)
        coordinator.hover(group: .shortTerm, before: short.id)
        precondition(coordinator.target?.highlightsGroupHeader == false)
        let consumedTarget = coordinator.finishDrop()
        precondition(consumedTarget?.beforeID == short.id)
        precondition(coordinator.target == nil)

        let firstSession = coordinator.beginDragging(task: short)
        let secondSession = coordinator.beginDragging(task: long)
        coordinator.cancel(sessionID: firstSession)
        precondition(coordinator.sessionID == secondSession)
        precondition(coordinator.sourceTask?.id == long.id)
        coordinator.cancel(sessionID: secondSession)
        precondition(coordinator.sessionID == nil)

        _ = coordinator.beginDragging(task: short)
        coordinator.hover(group: .longTerm, before: long.id)
        let finishedTarget = coordinator.finishDrop()
        precondition(finishedTarget?.beforeID == long.id)
        precondition(coordinator.target == nil)
        precondition(coordinator.sourceTask == nil)
        precondition(coordinator.sessionID == nil)
        coordinator.hover(group: .shortTerm, before: short.id)
        precondition(coordinator.target == nil)

        let staleSession = coordinator.beginDragging(task: short)
        _ = coordinator.finishDrop(sessionID: staleSession)
        let currentSession = coordinator.beginDragging(task: long)
        coordinator.hover(
            group: .shortTerm,
            before: short.id,
            sessionID: staleSession
        )
        precondition(coordinator.target == nil)
        coordinator.clearTarget(sessionID: staleSession)
        precondition(coordinator.sessionID == currentSession)

        let nextID = UUID()
        precondition(
            coordinator.dropTarget(
                group: .shortTerm,
                upperBeforeID: short.id,
                lowerBeforeID: nextID,
                locationY: 8,
                rowHeight: 40
            ) == TaskDropTarget(group: .shortTerm, beforeID: short.id)
        )
        precondition(
            coordinator.dropTarget(
                group: .shortTerm,
                upperBeforeID: short.id,
                lowerBeforeID: nextID,
                locationY: 32,
                rowHeight: 40
            ) == TaskDropTarget(group: .shortTerm, beforeID: nextID)
        )

        coordinator.beginDragging(task: short)
        coordinator.hover(group: .longTerm, before: long.id)
        precondition(store.shortTermTasks.map(\.id) == [short.id])
        precondition(store.longTermTasks.map(\.id) == [long.id])
        coordinator.cancel()
        precondition(store.shortTermTasks.map(\.id) == [short.id])
        precondition(store.longTermTasks.map(\.id) == [long.id])

        coordinator.beginDragging(task: short)
        coordinator.hover(group: .longTerm, before: long.id)
        try coordinator.performDrop(sourceID: short.id, store: store)
        precondition(store.longTermTasks.map(\.id) == [short.id, long.id])

        coordinator.beginDragging(task: long)
        coordinator.hover(group: .shortTerm, before: nil)
        try coordinator.performDrop(sourceID: long.id, store: store)
        precondition(store.shortTermTasks.map(\.id) == [long.id])

        let hierarchyStore = TaskStore(
            fileURL: directory.appendingPathComponent("hierarchy.json")
        )
        let parent = try hierarchyStore.add(text: "父任务")
        let childOne = try hierarchyStore.add(
            text: "子任务一",
            parentID: parent.id
        )
        let childTwo = try hierarchyStore.add(
            text: "子任务二",
            parentID: parent.id
        )
        coordinator.beginDragging(task: childTwo)
        coordinator.hover(
            group: .shortTerm,
            before: childOne.id,
            parentID: parent.id
        )
        try coordinator.performDrop(sourceID: childTwo.id, store: hierarchyStore)
        precondition(hierarchyStore.children(of: parent.id).map(\.id) == [childTwo.id, childOne.id])
        print("Task drop coordinator smoke passed.")
    }
}
