import Foundation
import Testing
import TaskCore
import GRDB
@testable import TaskStore

// Serialized: `suspendAll()` affects every store in the process.
@Suite(.serialized)
struct SQLiteStoreTests {
    let today = LocalDay(iso: "2026-10-14")!

    /// A database exercising every column: areas, tags (nested), projects, headings,
    /// repeats, checklists, reminders, deadlines, evening, Today order, soft deletes.
    func sample() -> TaskDatabase {
        var db = TaskDatabase()
        let work = db.addArea("Work")
        let parent = db.tag(named: "Places")
        db.addProject(Project(title: "Someday project", when: .someday))
        let project = db.addProject(Project(title: "Launch", notes: "v1", areaID: work.id, when: .on(today),
                                            deadline: today.adding(days: 30),
                                            repetition: Repetition(rule: RepeatRule(frequency: .yearly(month: 10, day: 14), anchor: today),
                                                                   occurrence: today, index: 3),
                                            tagIDs: [parent.id]))
        let heading = db.addHeading("Prep", toProject: project.id)
        let rule = RepeatRule(frequency: .monthly(.weekday(ordinal: -1, .friday)), interval: 2, mode: .afterCompletion,
                              end: .count(5), anchor: today, deadlineOffset: 3, reminder: TimeOfDay(hour: 8, minute: 30))
        db.add(Todo(title: "Report", notes: "**markdown**", projectID: project.id, headingID: heading.id, when: .on(today),
                    isEvening: true, deadline: today.adding(days: 2), reminder: TimeOfDay(hour: 21, minute: 5),
                    repetition: Repetition(rule: rule, occurrence: today, index: 2), tagIDs: [parent.id],
                    checklist: [ChecklistItem(title: "Draft", isDone: true), ChecklistItem(title: "Send")]), today: today)
        db.add(Todo(title: "Loose", areaID: work.id, when: .anytime), today: today)
        let done = db.add(Todo(title: "Done", when: .inbox), today: today)
        db.complete(done.id)
        let gone = db.add(Todo(title: "Gone"), today: today)
        db.trash(gone.id)
        return db
    }

    @Test func roundTripsEveryField() throws {
        let store = try SQLiteStore()
        let db = sample()
        try store.save(from: TaskDatabase(), to: db)
        #expect(try store.load() == db)
    }

    @Test func savesOnlyChangesAndHandlesRemovals() throws {
        let store = try SQLiteStore()
        var db = sample()
        try store.save(from: TaskDatabase(), to: db)

        let before = db
        let report = db.todos.values.first { $0.title == "Report" }!
        db.modify(report.id) { $0.title = "Report (edited)"; $0.checklist.removeFirst(); $0.tagIDs = [] }
        let heading = db.headings.values.first!
        db.removeHeading(heading.id)
        db.removeArea(db.areas.values.first!.id)
        db.purgeTrash(olderThan: 0)
        let loose = db.todos.values.first { $0.title == "Loose" }!
        _ = db.convertToProject(loose.id, today: today)
        try store.save(from: before, to: db)
        #expect(try store.load() == db)

        // Repeating the same save is harmless.
        try store.save(from: before, to: db)
        #expect(try store.load() == db)
    }

    @Test func replaceAll() throws {
        let store = try SQLiteStore()
        try store.save(from: TaskDatabase(), to: sample())
        var other = TaskDatabase()
        other.add(Todo(title: "Only me"), today: today)
        try store.replaceAll(with: other)
        #expect(try store.load() == other)
    }

    @Test func staysInitializedWhenEmptied() throws {
        let store = try SQLiteStore()
        #expect(try !store.isInitialized())
        let db = sample()
        try store.initialize(with: db)
        #expect(try store.isInitialized())
        #expect(try store.load() == db)

        // The user deletes everything: the store is empty but must not be re-seeded.
        try store.replaceAll(with: TaskDatabase())
        #expect(try store.isInitialized())
    }

    @Test func upgradeMarksStoresWithDataAsInitialized() throws {
        let withData = try DatabaseQueue()
        try Schema.migrator.migrate(withData, upTo: "v1")
        // A row as v1 stored it (today's row code needs later columns).
        try withData.write {
            try $0.execute(sql: "INSERT INTO area (id, title, sort_key, created_at, updated_at) VALUES (?, 'Work', 'V', 0, 0)",
                           arguments: [UUID().uuidString])
        }
        #expect(try SQLiteStore(writer: withData).isInitialized())

        let empty = try DatabaseQueue()
        try Schema.migrator.migrate(empty, upTo: "v1")
        #expect(try !SQLiteStore(writer: empty).isInitialized())
    }

    @Test func fileDatabaseSurvivesReopening() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("tasks.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = sample()
        do {
            let store = try SQLiteStore(url: url)
            try await store.save(from: TaskDatabase(), to: db)
        }
        let reopened = try SQLiteStore(url: url)
        #expect(try reopened.load() == db)
    }

    @Test func readOnlyStoreLoadsButCannotWrite() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("tasks.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = sample()
        try SQLiteStore(url: url).initialize(with: db)

        let reader = try SQLiteStore(readingFrom: url)
        #expect(try reader.load() == db)
        #expect(throws: (any Error).self) { try reader.save(from: db, to: TaskDatabase()) }
        #expect(throws: (any Error).self) { try SQLiteStore(readingFrom: url.deletingLastPathComponent().appendingPathComponent("missing.sqlite")) }
    }

    @Test func appAndWidgetWritesBothSurvive() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("tasks.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var base = TaskDatabase()
        let call = base.add(Todo(title: "Call", when: .on(today)), today: today)
        let write = base.add(Todo(title: "Write", when: .on(today)), today: today)
        let app = try SQLiteStore(url: url)
        try app.initialize(with: base)

        // The widget completes one to-do while the app edits another in memory.
        let widget = try SQLiteStore(url: url)
        try widget.update { _ = $0.complete(call.id) }
        var edited = base
        edited.modify(write.id) { $0.title = "Write report" }

        // The app saves only what it changed, from its stale snapshot, then reloads.
        try app.save(from: base, to: edited)
        let merged = try app.load()
        #expect(merged.todos[call.id]?.status == .completed)
        #expect(merged.todos[write.id]?.title == "Write report")
    }

    @Test func updateCompletesARepeatingTodoAndAddsTheNext() throws {
        let store = try SQLiteStore()
        var db = TaskDatabase()
        let rule = RepeatRule(frequency: .daily, anchor: today)
        let todo = db.add(Todo(title: "Stretch", when: .on(today), repetition: Repetition(rule: rule, occurrence: today)), today: today)
        try store.initialize(with: db)

        let saved = try store.update { _ = $0.complete(todo.id) }
        #expect(try store.load() == saved)
        #expect(saved.todos[todo.id]?.status == .completed)
        #expect(saved.todos.values.filter { $0.status == .open && $0.title == "Stretch" }.count == 1)
    }

    @Test func childTagBeforeParentIsFine() throws {
        // Dictionary order is arbitrary, so a child tag can be written before its parent.
        var db = TaskDatabase()
        let parent = db.tag(named: "Parent")
        var child = db.tag(named: "Child")
        child.parentID = parent.id
        let restored = TaskDatabase(todos: [], projects: [], headings: [], areas: [], tags: [child, parent])
        let store = try SQLiteStore()
        try store.save(from: TaskDatabase(), to: restored)
        #expect(try store.load().tags[child.id]?.parentID == parent.id)
    }

    @Test func suspendedStoreRefusesWritesUntilResumed() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("tasks.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try SQLiteStore(url: url)
        let db = sample()

        SQLiteStore.suspendAll()
        #expect(throws: (any Error).self) { try store.save(from: TaskDatabase(), to: db) }
        SQLiteStore.resumeAll()

        // The failed save changed nothing, so the same save works now.
        #expect(try store.load() == TaskDatabase())
        try store.save(from: TaskDatabase(), to: db)
        #expect(try store.load() == db)
    }
}
