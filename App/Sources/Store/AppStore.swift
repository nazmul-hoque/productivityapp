import Foundation
import Observation
import SwiftUI
import TaskCore
import TaskStore
import WidgetKit

/// The app's single source of state. Wraps the pure `TaskDatabase`, persists it after
/// each change, and keeps scheduled reminders in step.
@MainActor
@Observable
final class AppStore {
    private(set) var db: TaskDatabase
    private(set) var today: LocalDay

    /// `nil` if the database could not be opened; the app then runs without saving.
    @ObservationIgnored private let storage: SQLiteStore?
    /// What the database file currently holds, so a save writes only what changed since.
    @ObservationIgnored private var saved: TaskDatabase
    @ObservationIgnored private let reminders = ReminderScheduler()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The write in progress. Writes run one at a time so `saved` always matches the file.
    @ObservationIgnored private var writing: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    /// Called after local changes reach the database, so sync can follow them.
    @ObservationIgnored var onSaved: (() -> Void)?

    /// The database file, for sync. `nil` if it could not be opened.
    var database: SQLiteStore? { storage }

    init() {
        let today = LocalDay(Date())
        let (storage, database) = Persistence.open(today: today)
        self.storage = storage
        self.today = today
        db = database
        saved = database
    }

    /// Picks up a new day (Today/Upcoming are computed from `today`) and purges old trash.
    func refresh() {
        let now = LocalDay(Date())
        if now != today { today = now }
        perform { $0.purgeTrash() }
    }

    func syncReminders() async {
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
            await self.save()
            await self.reminders.sync(with: self.db)
        }
    }

    /// Writes pending changes now and returns once they are on disk (or the write failed).
    func save() async {
        while let current = writing { await current.value }
        guard let storage, db != saved else { return }
        let base = saved
        let snapshot = db
        let write = Task {
            do {
                try await storage.save(from: base, to: snapshot)
                saved = snapshot
                WidgetCenter.shared.reloadAllTimelines()
                onSaved?()
            } catch {
                // `saved` still matches the file, so the next save writes these rows again.
                print("Could not save: \(error)")
            }
        }
        writing = write
        await write.value
        writing = nil
    }

    /// Picks up what other processes (the widget) wrote while the app was away. Pending edits are
    /// saved first; a save writes only the rows the app changed, so theirs survive.
    func reloadFromDisk() async {
        guard let storage else { return }
        await save()
        guard let disk = try? await Task.detached(operation: { try storage.load() }).value else { return }
        // An edit made while loading isn't on disk yet; leave it and reload next time.
        guard db == saved, disk != saved else { return }
        db = disk
        saved = disk
        WidgetCenter.shared.reloadAllTimelines()
        await reminders.sync(with: db)
    }

    /// Applies a button tapped on a reminder notification and saves before returning, since iOS
    /// may suspend the app again right after.
    func handle(_ action: ReminderAction, for id: UUID) async {
        // iOS may have woken a suspended app just for this.
        SQLiteStore.resumeAll()
        defer { suspendDatabaseIfInBackground() }
        // The app may have been asleep while the widget changed things.
        await reloadFromDisk()
        switch action {
        case .snoozeHour: perform { $0.snooze(id, .oneHour) }
        case .snoozeTomorrow: perform { $0.snooze(id, .tomorrow) }
        case .complete: perform { _ = $0.complete(id) }
        }
        await save()
        await reminders.sync(with: db)
    }

    /// Saves when the app goes to the background, asking iOS for time to finish first, then
    /// suspends the database so the suspended app holds no lock on the shared file.
    func saveBeforeSuspending() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save") { [weak self] in
            // Out of time: give up on the write rather than be killed holding its lock.
            SQLiteStore.suspendAll()
            self?.endBackgroundTask()
        }
        Task {
            await save()
            suspendDatabaseIfInBackground()
            endBackgroundTask()
        }
    }

    /// Called when the app comes to the foreground, before anything reads or writes.
    func resumeDatabase() {
        SQLiteStore.resumeAll()
    }

    /// Suspends the database unless the app is back in the foreground by now (it may return
    /// while a background save is still running).
    func suspendDatabaseIfInBackground() {
        if UIApplication.shared.applicationState == .background {
            SQLiteStore.suspendAll()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Convenience

    var classifier: ListClassifier { db.classifier(today: today) }

    func quickAdd(_ text: String, context: QuickAddContext) {
        let parsed = QuickAddParser(today: today).parse(text)
        guard !parsed.title.isEmpty else { return }
        perform {
            _ = $0.add(parsed, defaultWhen: context.defaultWhen(today: today), evening: context.evening,
                       projectID: context.projectID, headingID: context.headingID, areaID: context.areaID,
                       at: context.insertion, today: today)
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
    /// A day in Upcoming.
    var day: LocalDay?
    /// The This Evening section of Today.
    var evening = false
    /// Where to put it, when the add button was dropped between two to-dos.
    var insertion: Insertion?

    func defaultWhen(today: LocalDay) -> When {
        if let day { return .on(day) }
        switch list {
        case .today: return .on(today)
        case .anytime: return .anytime
        case .someday: return .someday
        default: return .inbox
        }
    }
}
