import Combine
import Foundation

@MainActor
final class TaskDraftState: ObservableObject {
    @Published var text = ""
    @Published var afterID: UUID?
    @Published var group: TaskGroup = .shortTerm
    @Published var parentID: UUID? = nil
    @Published private(set) var isPresented = true

    @discardableResult
    func submit(to store: TaskStore) throws -> TaskItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let item = try store.add(
            text: text,
            after: afterID,
            group: group,
            parentID: parentID
        )
        text = ""
        afterID = nil
        parentID = nil
        isPresented = false
        return item
    }

    @discardableResult
    func submitAndContinue(to store: TaskStore) throws -> TaskItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let item = try store.add(
            text: text,
            after: afterID,
            group: group,
            parentID: parentID
        )
        text = ""
        afterID = item.id
        isPresented = true
        return item
    }

    func present(
        after id: UUID?,
        in group: TaskGroup = .shortTerm,
        parentID: UUID? = nil
    ) {
        afterID = id
        self.group = group
        self.parentID = parentID
        isPresented = true
    }

    func commitOrDismiss(to store: TaskStore) throws {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = ""
            afterID = nil
            parentID = nil
            isPresented = false
        } else {
            try submit(to: store)
        }
    }

    func syncVisibility(hasPendingTasks: Bool) {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            isPresented = true
        } else {
            isPresented = !hasPendingTasks
        }
    }

    func dismissIfEmpty() {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        afterID = nil
        parentID = nil
        isPresented = false
    }
}
