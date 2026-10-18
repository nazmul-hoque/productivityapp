import Foundation
import Observation
import SwiftUI
import TaskCore

/// The app's single source of state. Wraps the pure `TaskDatabase`, persists it after
/// each change, and keeps scheduled reminders in step.
@MainActor
@Observable
final class AppStore {
    private(set) var db: TaskDatabase
    private(set) var today: LocalDay

    @ObservationIgnored private let persistence: Persistence
    @ObservationIgnored private let reminders = ReminderScheduler()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(persistence: Persistence = Persistence()) {
        let today = LocalDay(Date())
        self.persistence = persistence
        self.today = today
        if let saved = persistence.load() {
            db = saved
        } else {
            db = SampleData.database(today: today)
        }
    }

    /// Picks up a new day (Today/Upcoming are computed from `today`) and purges old trash.
    func refresh() {
        let now = LocalDay(Date())
        if now != today { today = now }
        perform { $0.purgeTrash() }
    }

    func requestNotificationPermission() async {
        await reminders.requestAuthorization()
        await reminders.sync(with: db)
    }

    /// Applies a change and saves shortly afterwards (edits in quick succession are batched).
    func perform(_ change: (inout TaskDatabase) -> Void) {
        change(&db)
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.persistence.save(self.db)
            await self.reminders.sync(with: self.db)
        }
    }

    // MARK: - Convenience

    var classifier: ListClassifier { db.classifier(today: today) }

    func quickAdd(_ text: String, context: QuickAddContext) {
        let parsed = QuickAddParser(today: today).parse(text)
        guard !parsed.title.isEmpty else { return }
        perform {
            _ = $0.add(parsed, defaultWhen: context.defaultWhen(today: today), projectID: context.projectID,
                   headingID: context.headingID, areaID: context.areaID, today: today)
        }
    }

    func complete(_ id: UUID) { perform { _ = $0.complete(id) } }
    func cancel(_ id: UUID) { perform { _ = $0.cancel(id) } }
    func reopen(_ id: UUID) { perform { $0.reopen(id) } }
    func trash(_ id: UUID) { perform { $0.trash(id) } }
    func restore(_ id: UUID) { perform { $0.restore(id) } }

    func schedule(_ id: UUID, _ when: When, evening: Bool = false) {
        perform { $0.schedule(id, when, evening: evening, today: today) }
    }

    /// Applies `List.onMove` to `items` (one section, in display order).
    func move(in items: [Todo], from source: IndexSet, to destination: Int, inToday: Bool = false) {
        guard let first = source.first else { return }
        let moved = items[first].id
        var ids = items.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        guard let index = ids.firstIndex(of: moved) else { return }
        let previous = index > 0 ? ids[index - 1] : nil
        let next = index + 1 < ids.count ? ids[index + 1] : nil
        perform { $0.reorder(moved, after: previous, before: next, inToday: inToday) }
    }

    func title(of container: Container) -> String? {
        switch container {
        case .none: return nil
        case .project(let id): return db.projects[id]?.title
        case .area(let id): return db.areas[id]?.title
        }
    }
}

/// Where a to-do lives.
enum Container: Hashable {
    case none
    case project(UUID)
    case area(UUID)

    init(_ todo: Todo) {
        if let id = todo.projectID { self = .project(id) }
        else if let id = todo.areaID { self = .area(id) }
        else { self = .none }
    }
}

/// Defaults for a new to-do, based on the screen it was added from.
struct QuickAddContext: Equatable {
    var list: SmartList?
    var projectID: UUID?
    var headingID: UUID?
    var areaID: UUID?

    func defaultWhen(today: LocalDay) -> When {
        switch list {
        case .today: return .on(today)
        case .anytime: return .anytime
        case .someday: return .someday
        default: return .inbox
        }
    }
}
