import CoreSpotlight
import Foundation
import TaskCore
import UniformTypeIdentifiers

/// Keeps open to-dos searchable from Spotlight (on this device only). Tapping a result opens
/// the to-do. Updates a few seconds after changes, sending only what changed.
@MainActor
final class SpotlightIndex {
    static let activityType = CSSearchableItemActionType
    private static let domain = "com.nazmulhoque.daybook.todo"

    private let index = CSSearchableIndex.default()
    /// What's in the index, by to-do: a summary of the indexed fields, to spot changes.
    private var indexed: [UUID: String]?
    private var pending: Task<Void, Never>?

    /// Schedules an update to match `db`.
    func update(with db: TaskDatabase, after delay: Duration = .seconds(3)) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await apply(db)
        }
    }

    private func apply(_ db: TaskDatabase) async {
        if indexed == nil {
            // First update since launch: start from a clean index.
            try? await index.deleteSearchableItems(withDomainIdentifiers: [Self.domain])
            indexed = [:]
        }
        var wanted: [UUID: (signature: String, item: CSSearchableItem)] = [:]
        for todo in db.todos.values where todo.status == .open && !todo.isDeleted {
            let item = Self.item(for: todo, in: db)
            wanted[todo.id] = (Self.signature(item), item)
        }
        let changed = wanted.filter { indexed?[$0.key] != $0.value.signature }
        let removed = (indexed ?? [:]).keys.filter { wanted[$0] == nil }
        do {
            if !removed.isEmpty {
                try await index.deleteSearchableItems(withIdentifiers: removed.map(\.uuidString))
            }
            if !changed.isEmpty {
                try await index.indexSearchableItems(changed.values.map(\.item))
            }
            indexed = wanted.mapValues(\.signature)
        } catch {
            indexed = nil  // Start over next time.
        }
    }

    private static func item(for todo: Todo, in db: TaskDatabase) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = todo.title
        var details: [String] = []
        if let project = todo.projectID.flatMap({ db.projects[$0] }) { details.append(project.title) }
        if let area = todo.areaID.flatMap({ db.areas[$0] }) { details.append(area.title) }
        if case .on(let day) = todo.when { details.append(day.description) }
        if !todo.notes.isEmpty { details.append(todo.notes) }
        attributes.contentDescription = details.joined(separator: " · ")
        attributes.keywords = todo.tagIDs.compactMap { db.tags[$0]?.title } + todo.checklist.map(\.title)
        return CSSearchableItem(uniqueIdentifier: todo.id.uuidString, domainIdentifier: domain, attributeSet: attributes)
    }

    private static func signature(_ item: CSSearchableItem) -> String {
        let a = item.attributeSet
        return [a.title ?? "", a.contentDescription ?? "", (a.keywords ?? []).joined(separator: "\u{1F}")].joined(separator: "\u{1E}")
    }

    /// The to-do a Spotlight result stands for.
    static func todoID(from activity: NSUserActivity) -> UUID? {
        (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init)
    }
}
