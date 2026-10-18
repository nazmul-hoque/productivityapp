import Foundation
import Testing
import TaskCore
@testable import TaskStore

/// An in-memory stand-in for the Supabase functions: merges pushed records field by field and
/// hands out changes in version order, like `sync_push` / `sync_pull`.
actor FakeServer: SyncTransport {
    private var records: [String: (record: SyncRecord, version: Int64)] = [:]
    private var version: Int64 = 0
    var pushCount = 0

    func push(_ incoming: [SyncRecord]) async throws {
        pushCount += 1
        for record in incoming {
            let key = "\(record.entity.rawValue)/\(record.id)"
            let merged = SyncRecord.merge(records[key]?.record, record)
            if merged != records[key]?.record {
                version += 1
                records[key] = (merged, version)
            }
        }
    }

    func pull(since cursor: Int64, limit: Int) async throws -> SyncPage {
        let page = records.values.filter { $0.version > cursor }.sorted { $0.version < $1.version }.prefix(limit)
        return SyncPage(records: page.map(\.record), cursor: page.last?.version ?? cursor)
    }

    func record(_ entity: Entity, _ id: UUID) -> SyncRecord? {
        records["\(entity.rawValue)/\(id)"]?.record
    }
}

/// A simulated device: its own store and an in-memory copy, edited the way the app does.
final class Device: @unchecked Sendable {
    let store: SQLiteStore
    let engine: SyncEngine
    let today = LocalDay(iso: "2026-10-14")!

    init(server: any SyncTransport, pageSize: Int = 500) throws {
        store = try SQLiteStore()
        engine = SyncEngine(store: store, transport: server, pageSize: pageSize)
    }

    var db: TaskDatabase { get throws { try store.load() } }

    /// An edit as the app makes it: change the loaded copy, save the difference.
    @discardableResult
    func edit(_ change: (inout TaskDatabase) -> Void) throws -> TaskDatabase {
        let before = try store.load()
        var after = before
        change(&after)
        try store.save(from: before, to: after)
        // Distinct milliseconds between devices' edits, so "later" is unambiguous.
        Thread.sleep(forTimeInterval: 0.003)
        return after
    }

    @discardableResult
    func sync() async throws -> SyncResult {
        try await engine.sync()
    }
}

@Suite(.serialized)
struct SyncTests {
    let today = LocalDay(iso: "2026-10-14")!

    @Test func newDeviceReceivesEverything() async throws {
        let server = FakeServer()
        let phone = try Device(server: server)
        try phone.edit { db in
            let project = db.addProject(Project(title: "Trip"))
            let heading = db.addHeading("Packing", toProject: project.id)
            db.add(Todo(title: "Passport", projectID: project.id, headingID: heading.id, when: .anytime,
                        checklist: [ChecklistItem(title: "Renew")]), today: today)
            db.add(Todo(title: "Call mum", when: .on(today), reminder: TimeOfDay(hour: 18), tagIDs: [db.tag(named: "Phone").id]), today: today)
        }
        let first = try await phone.sync()
        #expect(first.pushed == 5)

        let tablet = try Device(server: server)
        let result = try await tablet.sync()
        #expect(result.changedLocally)
        #expect(try tablet.db == phone.db)

        // Nothing left to do on either side.
        let echo = try await phone.sync()
        #expect(echo.pushed == 0 && !echo.changedLocally)
        let again = try await tablet.sync()
        #expect(again.pushed == 0 && !again.changedLocally)
    }

    @Test func editsToDifferentFieldsBothSurvive() async throws {
        let server = FakeServer()
        let phone = try Device(server: server)
        let todo = try phone.edit { $0.add(Todo(title: "Report", when: .anytime), today: today) }.todos.values.first!
        try await phone.sync()
        let laptop = try Device(server: server)
        try await laptop.sync()

        // Offline on both: the phone renames it, the laptop schedules it for today.
        try phone.edit { $0.modify(todo.id) { $0.title = "Quarterly report" } }
        try laptop.edit { $0.schedule(todo.id, .on(today), today: today) }
        try await phone.sync()
        try await laptop.sync()
        try await phone.sync()

        for device in [phone, laptop] {
            let merged = try device.db.todos[todo.id]!
            #expect(merged.title == "Quarterly report")
            #expect(merged.when == .on(today))
        }
        #expect(try phone.db == laptop.db)
    }

    @Test func laterEditToTheSameFieldWins() async throws {
        let server = FakeServer()
        let phone = try Device(server: server)
        let todo = try phone.edit { $0.add(Todo(title: "Draft"), today: today) }.todos.values.first!
        try await phone.sync()
        let laptop = try Device(server: server)
        try await laptop.sync()

        try phone.edit { $0.modify(todo.id) { $0.title = "Phone title" } }
        try laptop.edit { $0.modify(todo.id) { $0.title = "Laptop title" } }  // later
        // Sync in the "wrong" order: the earlier edit reaches the server last.
        try await laptop.sync()
        try await phone.sync()
        try await laptop.sync()

        #expect(try phone.db.todos[todo.id]?.title == "Laptop title")
        #expect(try laptop.db.todos[todo.id]?.title == "Laptop title")
    }

    @Test func deletionWinsOverAnEdit() async throws {
        let server = FakeServer()
        let phone = try Device(server: server)
        let todo = try phone.edit { $0.add(Todo(title: "Old idea"), today: today) }.todos.values.first!
        try await phone.sync()
        let laptop = try Device(server: server)
        try await laptop.sync()

        // The phone empties the trash (a real delete); the laptop edits the same to-do later.
        try phone.edit { $0.trash(todo.id); $0.purgeTrash(olderThan: 0) }
        try laptop.edit { $0.modify(todo.id) { $0.notes = "but wait" } }
        try await phone.sync()
        try await laptop.sync()
        try await phone.sync()

        #expect(try phone.db.todos[todo.id] == nil)
        #expect(try laptop.db.todos[todo.id] == nil)
        #expect(await server.record(.todo, todo.id)?.deleted == true)
    }

    @Test func referencesToRowsDeletedElsewhereAreRepaired() async throws {
        let server = FakeServer()
        let phone = try Device(server: server)
        var headingID: UUID!
        var todoID: UUID!
        try phone.edit { db in
            let project = db.addProject(Project(title: "Move"))
            headingID = db.addHeading("Boxes", toProject: project.id).id
            todoID = db.add(Todo(title: "Tape", projectID: project.id, when: .anytime), today: today).id
        }
        try await phone.sync()
        let laptop = try Device(server: server)
        try await laptop.sync()

        // The laptop files the to-do under the heading; the phone deletes the heading.
        try laptop.edit { $0.modify(todoID) { $0.headingID = headingID } }
        try phone.edit { $0.removeHeading(headingID) }
        try await phone.sync()
        try await laptop.sync()
        try await phone.sync()

        for device in [phone, laptop] {
            let db = try device.db
            #expect(db.headings[headingID] == nil)
            #expect(db.todos[todoID]?.headingID == nil)
        }
        #expect(try phone.db == laptop.db)
    }

    @Test func changesFromOtherWritersSync() async throws {
        // A widget completing a to-do goes through `update`, which tracks changes the same way.
        let server = FakeServer()
        let phone = try Device(server: server)
        let rule = RepeatRule(frequency: .daily, anchor: today)
        let todo = try phone.edit {
            $0.add(Todo(title: "Stretch", when: .on(today), repetition: Repetition(rule: rule, occurrence: today)), today: today)
        }.todos.values.first!
        try await phone.sync()

        try phone.store.update { _ = $0.complete(todo.id) }
        try await phone.sync()
        let laptop = try Device(server: server)
        try await laptop.sync()
        let db = try laptop.db
        #expect(db.todos[todo.id]?.status == .completed)
        #expect(db.todos.count == 2)  // and the next instance
    }

    @Test func editMadeDuringAPushStaysQueued() async throws {
        let store = try SQLiteStore()
        let before = TaskDatabase()
        var after = before
        let todo = after.add(Todo(title: "One"), today: today)
        try await store.save(from: before, to: after)

        let (records, upTo) = try await store.pendingChanges()
        #expect(records.count == 1)
        // Edited again before the push finishes.
        var edited = after
        edited.modify(todo.id) { $0.title = "One, edited" }
        try await store.save(from: after, to: edited)
        try await store.markPushed(upTo: upTo)

        let (remaining, _) = try await store.pendingChanges()
        #expect(remaining.map(\.id) == [todo.id])
        #expect(remaining.first?.fields["title"] == .string("One, edited"))
    }

    @Test func pullsInPagesAndMergesOnce() async throws {
        let server = FakeServer()
        let phone = try Device(server: server, pageSize: 2)
        try phone.edit { db in
            for n in 1...5 { db.add(Todo(title: "Item \(n)"), today: today) }
        }
        try await phone.sync()
        #expect(await server.pushCount == 3)

        let laptop = try Device(server: server, pageSize: 2)
        let result = try await laptop.sync()
        #expect(result.pulled == 5)
        #expect(try laptop.db.todos.count == 5)
    }

    @Test func onlyChangedFieldsGetNewClocks() async throws {
        let server = FakeServer()
        let phone = try Device(server: server)
        let todo = try phone.edit { $0.add(Todo(title: "A", notes: "n"), today: today) }.todos.values.first!
        try await phone.sync()
        let before = await server.record(.todo, todo.id)!

        try phone.edit { $0.modify(todo.id) { $0.title = "B" } }
        try await phone.sync()
        let after = await server.record(.todo, todo.id)!
        #expect(after.clocks["title"]! > before.clocks["title"]!)
        #expect(after.clocks["notes"] == before.clocks["notes"])
    }

    @Test func clocksOrderAsStrings() {
        let a = HLC(milliseconds: 999, counter: 0, node: "aaaa")
        let b = HLC(milliseconds: 1000, counter: 0, node: "aaaa")
        #expect(a < b)
        #expect(a.description < b.description)
        #expect(HLC(a.description) == a)
        let ticked = HLC.tick(after: b, now: Date(timeIntervalSince1970: 0.5), node: "bbbb")
        #expect(ticked > b)  // a wall clock behind doesn't go backwards
        let received = HLC.receive(HLC(milliseconds: 5000, counter: 2, node: "cccc"), last: b, node: "bbbb")
        #expect(HLC.tick(after: received, now: Date(timeIntervalSince1970: 1), node: "bbbb") > HLC(milliseconds: 5000, counter: 2, node: "cccc"))
    }
}
