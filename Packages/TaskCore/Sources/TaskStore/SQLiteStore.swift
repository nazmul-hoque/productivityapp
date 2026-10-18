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

    /// An in-memory database, for tests and previews.
    public init() throws {
        writer = try DatabaseQueue(configuration: Self.configuration)
        try Schema.migrator.migrate(writer)
    }

    private static var configuration: Configuration {
        var config = Configuration()
        config.label = "TaskStore"
        // Another process (a widget) may hold a lock briefly.
        config.busyMode = .timeout(5)
        return config
    }

    /// Whether the store holds no data yet (a fresh install, or before migrating old data).
    public func isEmpty() throws -> Bool {
        try writer.read { db in
            try ["todo", "project", "area", "tag"].allSatisfy { table in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0
            }
        }
    }

    public func load() throws -> TaskDatabase {
        try writer.read(Rows.loadAll)
    }

    /// Writes every row of `database`, replacing whatever is stored.
    public func replaceAll(with database: TaskDatabase) throws {
        try writer.write { db in
            for table in ["todo_tag", "checklist_item", "todo", "heading", "project_tag", "project", "area_tag", "area", "tag"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
            try Self.write(Changes(from: TaskDatabase(), to: database), in: db)
        }
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

    private static func write(_ changes: Changes, in db: Database) throws {
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

    init(from old: TaskDatabase, to new: TaskDatabase) {
        (areas, removed.areas) = Self.diff(old.areas, new.areas)
        (tags, removed.tags) = Self.diff(old.tags, new.tags)
        (projects, removed.projects) = Self.diff(old.projects, new.projects)
        (headings, removed.headings) = Self.diff(old.headings, new.headings)
        (todos, removed.todos) = Self.diff(old.todos, new.todos)
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
