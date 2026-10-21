import Foundation

private struct FailingCLIWriter: AtomicWriting {
    func write(_ data: Data, to destinationURL: URL) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
}

@main
struct TaskCLISmoke {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MonoListCLI-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tasks.json")
        let store = TaskStore(fileURL: url)
        func persisted(_ tasks: [TaskItem]) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(tasks)
        }
        func apply(_ operations: [TaskCLIOperation], confirm: Bool = false) throws {
            _ = try store.applyCLI(TaskCLIBatch(expectedRevision: store.cliSnapshot().revision,
                                               confirm: confirm, operations: operations))
        }
        func rejects(_ batch: TaskCLIBatch) {
            let before = store.tasks
            do { _ = try store.applyCLI(batch); preconditionFailure("Expected rejection") }
            catch { precondition(store.tasks == before) }
        }
        let root = UUID(), second = UUID(), child = UUID()
        try apply([.init(kind: "add", id: root, text: "Parent"),
                   .init(kind: "add", id: second, text: "Second"),
                   .init(kind: "add", id: child, text: "Child", parentID: root)])
        precondition(store.children(of: root).map(\.id) == [child])
        let stale = try store.cliSnapshot().revision
        try store.updateText(id: second, text: "UI edit")
        rejects(.init(expectedRevision: stale, confirm: false,
                      operations: [.init(kind: "edit", id: second, text: "stale")]))
        rejects(.init(expectedRevision: try store.cliSnapshot().revision, confirm: false,
                      operations: [.init(kind: "edit", id: second, text: "must roll back"),
                                   .init(kind: "edit", id: UUID(), text: "missing")]))
        let onDisk = TaskStore(fileURL: url)
        let storedEncoding = try persisted(onDisk.tasks)
        precondition(storedEncoding == (try! persisted(store.tasks)))
        rejects(.init(expectedRevision: try store.cliSnapshot().revision, confirm: false,
                      operations: [.init(kind: "delete", id: root)]))
        rejects(.init(expectedRevision: try store.cliSnapshot().revision, confirm: true,
                      operations: [.init(kind: "add", id: root, text: "duplicate")]))
        rejects(.init(expectedRevision: try store.cliSnapshot().revision, confirm: false,
                      operations: [.init(kind: "reorder", ids: [root])]))
        try apply([.init(kind: "edit", id: second, text: "Polished"),
                   .init(kind: "move", id: second, beforeID: root)])
        precondition(store.topLevelPendingTasks.first?.id == second)
        try apply([.init(kind: "reorder", ids: [root, child, second])])
        try apply([.init(kind: "indent", id: second)])
        precondition(store.tasks.first { $0.id == second }?.parentID == root)
        try apply([.init(kind: "outdent", id: second)])
        precondition(store.tasks.first { $0.id == second }?.parentID == nil)
        try apply([.init(kind: "parent", id: second, parentID: root)])
        try apply([.init(kind: "parent", id: second)])
        let reminder = TaskReminder.daily(minuteOfDay: 600)
        try apply([.init(kind: "reminder", id: second, reminder: reminder)])
        precondition(store.tasks.first { $0.id == second }?.reminder == reminder)
        try apply([.init(kind: "reminder", id: second)])
        precondition(store.tasks.first { $0.id == second }?.reminder == nil)
        try apply([.init(kind: "complete", id: root)])
        precondition(store.historyTasks.count == 2)
        try apply([.init(kind: "restore", id: child)])
        precondition(store.pendingTasks.count == 3)
        try apply([.init(kind: "complete", id: second), .init(kind: "clear.history")], confirm: true)
        precondition(store.historyTasks.isEmpty)
        let beforeClear = store.tasks
        try apply([.init(kind: "clear.pending")], confirm: true)
        precondition(store.tasks.isEmpty)
        // Exercise the documented recovery path on synthetic data.
        let backup = url.deletingPathExtension().appendingPathExtension("cli-backup.json")
        try FileManager.default.copyItem(at: backup, to: directory.appendingPathComponent("recovered.json"))
        let recovered = TaskStore(fileURL: directory.appendingPathComponent("recovered.json"))
        precondition(Set(recovered.tasks.map(\.id)) == Set(beforeClear.map(\.id)))
        try apply([.init(kind: "add", text: "Before failed save")])
        let failing = TaskStore(fileURL: url, writer: FailingCLIWriter())
        let original = failing.tasks
        do {
            _ = try failing.applyCLI(.init(expectedRevision: failing.cliSnapshot().revision, confirm: false,
                operations: [.init(kind: "add", text: "Must not survive")]))
            preconditionFailure("Expected write failure")
        } catch { precondition(failing.tasks == original) }
        let failedEncoding = try persisted(TaskStore(fileURL: url).tasks)
        precondition(failedEncoding == (try! persisted(original)))
        try apply([.init(kind: "clear.all")], confirm: true)
        precondition(store.tasks.isEmpty)
        print("Task CLI smoke passed.")
    }
}
