import Foundation
import GRDB
import TaskCore

/// Persists a `TaskDatabase` in SQLite.
///
/// The app keeps working on the in-memory `TaskDatabase`; after a change it hands this
/// store the previous and current snapshots and only the rows that differ are written,
/// in one transaction. The file uses WAL mode so widgets and extensions can read it
/// while the app writes.
public final class SQLiteStore: Sendable {
    private let writer: any DatabaseWriter

    /// Opens (creating if needed) the database file at `url` and migrates it.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try DatabasePool(path: url.path, configuration: Self.configuration)
        try Schema.migrator.migrate(writer)
    }

    /// Opens an existing database file without migrating or writing to it, for widgets and
    /// extensions that only show data. The app owns the schema; any write through this store throws.
    public convenience init(readingFrom url: URL) throws {
        var config = Self.configuration
        config.readonly = true
        try self.init(writer: DatabasePool(path: url.path, configuration: config), migrate: false)
    }

    /// An in-memory database, for tests and previews.
    public convenience init() throws {
        try self.init(writer: DatabaseQueue(configuration: Self.configuration))
    }

    /// Wraps an open database and migrates it.
    init(writer: any DatabaseWriter, migrate: Bool = true) throws {
        self.writer = writer
        if migrate { try Schema.migrator.migrate(writer) }
    }

    private static var configuration: Configuration {
        var config = Configuration()
        config.label = "TaskStore"
        // Another process (a widget) may hold a lock briefly.
        config.busyMode = .timeout(5)
        // See `suspendAll()`.
        config.observesSuspensionNotifications = true
        return config
    }

    /// Stops every store in this process from taking new database locks, until `resumeAll()`.
    ///
    /// iOS kills a suspended app that holds a lock on a file in a shared App Group container
    /// (`0xdead10cc`). Call this once pending writes are done and the app is about to be
    /// suspended. Meanwhile writes throw (`SQLITE_INTERRUPT` / `SQLITE_ABORT`); reads still work.
    public static func suspendAll() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    /// Lets stores take locks again after `suspendAll()`.
    public static func resumeAll() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }

    /// Whether the store has been given its first contents (see `initialize(with:)`). It stays
    /// initialized even if the user later deletes everything.
    public func isInitialized() throws -> Bool {
        try writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'initialized'") != nil
        }
    }

    /// Fills a new store (with imported or sample data) and marks it initialized, in one transaction.
    public func initialize(with database: TaskDatabase) throws {
        try writer.write { db in
            try Self.replaceAll(with: database, in: db)
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES ('initialized', '1')")
        }
    }

    public func load() throws -> TaskDatabase {
        try writer.read(Rows.loadAll)
    }

    /// Loads, changes and saves in one transaction, for writers other than the app (a widget
    /// button, the share extension). Another process can't write in between, so its changes
    /// aren't lost. Returns the database as saved.
    @discardableResult
    public func update(_ change: (inout TaskDatabase) -> Void) throws -> TaskDatabase {
        try writer.write { db in
            let before = try Rows.loadAll(db)
            var after = before
            change(&after)
            try Self.write(Changes(from: before, to: after), in: db)
            return after
        }
    }

    // MARK: - Sync

    /// Local changes not yet pushed, and a token to pass to `markPushed(upTo:)` once they are.
    public func pendingChanges() async throws -> (records: [SyncRecord], upTo: Int64) {
        try await writer.read { db in try SyncLog.pending(in: db) }
    }

    public func markPushed(upTo seq: Int64) async throws {
        try await writer.write { db in try SyncLog.markPushed(upTo: seq, in: db) }
    }

    /// The server position this store has pulled up to.
    public func syncCursor() async throws -> Int64 {
        try await writer.read { db in try SyncLog.cursor(in: db) }
    }

    /// Merges pulled records and advances the cursor, in one transaction. Returns whether the
    /// local data changed (the app should reload).
    @discardableResult
    public func applyRemote(_ records: [SyncRecord], cursor: Int64) async throws -> Bool {
        try await writer.write { db in try SyncLog.apply(records, cursor: cursor, in: db) }
    }

    /// The account this store last synced with, if any.
    public func syncAccount() async throws -> UUID? {
        try await writer.read { db in try SyncLog.account(in: db) }
    }

    /// Whether there are any to-dos, projects, areas or tags.
    public func hasLocalData() async throws -> Bool {
        try await writer.read { db in try SyncLog.hasData(in: db) }
    }

    /// Prepares to sync with a newly signed-in account: everything is pulled again, and local data
    /// is either uploaded to the account (merged) or erased so the device shows only the account's.
    public func adoptAccount(_ account: UUID, keepingLocalData: Bool) async throws {
        try await writer.write { db in try SyncLog.adopt(account: account, keepingLocalData: keepingLocalData, in: db) }
    }

    /// Forgets the synced account (after it was deleted), keeping local data.
    public func detachFromAccount() async throws {
        try await writer.write { db in try SyncLog.detach(in: db) }
    }

    /// Writes every row of `database`, replacing whatever is stored.
    public func replaceAll(with database: TaskDatabase) throws {
        try writer.write { db in try Self.replaceAll(with: database, in: db) }
    }

    private static func replaceAll(with database: TaskDatabase, in db: Database) throws {
        // Local replacement: the old rows' sync bookkeeping goes too, and nothing is tombstoned.
        for table in ["todo_tag", "checklist_item", "todo", "heading", "project_tag", "project", "area_tag", "area", "tag",
                      "sync_clock", "sync_outbox", "sync_tombstone"] {
            try db.execute(sql: "DELETE FROM \(table)")
        }
        try write(Changes(from: TaskDatabase(), to: database), in: db)
    }

    /// Writes the rows that differ between two snapshots. Safe to repeat: writing the same
    /// change twice leaves the same result.
    public func save(from old: TaskDatabase, to new: TaskDatabase) throws {
        let changes = Changes(from: old, to: new)
        guard !changes.isEmpty else { return }
        try writer.write { db in try Self.write(changes, in: db) }
    }

    /// `save(from:to:)` off the calling thread.
    public func save(from old: TaskDatabase, to new: TaskDatabase) async throws {
        let changes = Changes(from: old, to: new)
        guard !changes.isEmpty else { return }
        try await writer.write { db in try Self.write(changes, in: db) }
    }

    /// Writes the rows and records the change for sync (field clocks, outbox, tombstones).
    static func write(_ changes: Changes, in db: Database) throws {
        try writeRows(changes, in: db)
        try SyncLog.record(changes, in: db)
    }

    /// Writes the rows only; used when applying changes that came from the server.
    static func writeRows(_ changes: Changes, in db: Database) throws {
        // Rows may reference ones written later in the same transaction (a child tag before its parent).
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        let now = Date()
        for area in changes.areas { try Rows.upsert(area, now: now, in: db) }
        for tag in changes.tags { try Rows.upsert(tag, now: now, in: db) }
        for project in changes.projects { try Rows.upsert(project, in: db) }
        for heading in changes.headings { try Rows.upsert(heading, now: now, in: db) }
        for todo in changes.todos { try Rows.upsert(todo, in: db) }

        for id in changes.removed.todos { try Rows.delete(from: "todo", id: id, in: db) }
        for id in changes.removed.headings { try Rows.delete(from: "heading", id: id, in: db) }
        for id in changes.removed.projects { try Rows.delete(from: "project", id: id, in: db) }
        for id in changes.removed.tags { try Rows.delete(from: "tag", id: id, in: db) }
        for id in changes.removed.areas { try Rows.delete(from: "area", id: id, in: db) }
    }
}

/// The rows to write to turn one snapshot into another.
struct Changes: Sendable {
    var areas: [Area] = []
    var tags: [Tag] = []
    var projects: [Project] = []
    var headings: [Heading] = []
    var todos: [Todo] = []
    var removed = Removed()

    struct Removed: Sendable {
        var areas: [UUID] = []
        var tags: [UUID] = []
        var projects: [UUID] = []
        var headings: [UUID] = []
        var todos: [UUID] = []
    }

    /// For sync: which fields of each changed row differ (all of them for a new row).
    var fieldChanges: [FieldChange] = []

    struct FieldChange: Sendable {
        var entity: Entity
        var id: UUID
        var fields: [String]
    }

    init(from old: TaskDatabase, to new: TaskDatabase) {
        (areas, removed.areas) = Self.diff(old.areas, new.areas)
        (tags, removed.tags) = Self.diff(old.tags, new.tags)
        (projects, removed.projects) = Self.diff(old.projects, new.projects)
        (headings, removed.headings) = Self.diff(old.headings, new.headings)
        (todos, removed.todos) = Self.diff(old.todos, new.todos)
        fieldChanges = Self.fieldChanges(.area, old.areas, areas)
            + Self.fieldChanges(.tag, old.tags, tags)
            + Self.fieldChanges(.project, old.projects, projects)
            + Self.fieldChanges(.heading, old.headings, headings)
            + Self.fieldChanges(.todo, old.todos, todos)
    }

    /// Removed rows, by entity.
    var removedKeys: [(Entity, UUID)] {
        removed.areas.map { (.area, $0) } + removed.tags.map { (.tag, $0) } + removed.projects.map { (.project, $0) }
            + removed.headings.map { (.heading, $0) } + removed.todos.map { (.todo, $0) }
    }

    private static func fieldChanges<T: Encodable & Identifiable>(_ entity: Entity, _ old: [UUID: T], _ changed: [T]) -> [FieldChange]
    where T.ID == UUID {
        changed.compactMap { item in
            let new = (try? RecordCoding.fields(of: item)) ?? [:]
            let previous = old[item.id].flatMap { try? RecordCoding.fields(of: $0) }
            let fields = RecordCoding.changedFields(previous, new)
            return fields.isEmpty ? nil : FieldChange(entity: entity, id: item.id, fields: fields)
        }
    }

    var isEmpty: Bool {
        areas.isEmpty && tags.isEmpty && projects.isEmpty && headings.isEmpty && todos.isEmpty
            && removed.areas.isEmpty && removed.tags.isEmpty && removed.projects.isEmpty
            && removed.headings.isEmpty && removed.todos.isEmpty
    }

    private static func diff<T: Equatable>(_ old: [UUID: T], _ new: [UUID: T]) -> (changed: [T], removed: [UUID]) {
        let changed = new.compactMap { id, value in old[id] == value ? nil : value }
        let removed = old.keys.filter { new[$0] == nil }
        return (changed, removed)
    }
}
