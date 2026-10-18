import Foundation
import TaskCore

/// The kinds of rows that sync.
public enum Entity: String, Codable, CaseIterable, Sendable {
    case area, tag, project, heading, todo
}

/// One synced row: its fields as JSON, the clock of each field's last change, and whether it
/// has been deleted. This is the unit sent to and received from the server.
///
/// Fields are the top-level keys of the model's `Codable` form (`title`, `when`, `checklist`…), so
/// two devices changing different fields of the same to-do both keep their change; for the same
/// field, the later clock wins. A deletion wins over any edit.
public struct SyncRecord: Codable, Equatable, Sendable {
    public var entity: Entity
    public var id: UUID
    public var fields: [String: JSONValue]
    public var clocks: [String: String]
    public var deleted: Bool

    public init(entity: Entity, id: UUID, fields: [String: JSONValue], clocks: [String: String], deleted: Bool = false) {
        self.entity = entity
        self.id = id
        self.fields = fields
        self.clocks = clocks
        self.deleted = deleted
    }

    /// The clock key that records a deletion.
    static let deletedField = "_deleted"

    static func tombstone(_ entity: Entity, id: UUID, clock: String) -> SyncRecord {
        SyncRecord(entity: entity, id: id, fields: [:], clocks: [deletedField: clock], deleted: true)
    }

    /// Combines two versions of the same record, field by field.
    public static func merge(_ local: SyncRecord?, _ remote: SyncRecord) -> SyncRecord {
        guard let local else { return remote }
        if local.deleted || remote.deleted {
            let clock = [local.clocks[deletedField], remote.clocks[deletedField]].compactMap { $0 }.max() ?? ""
            return tombstone(remote.entity, id: remote.id, clock: clock)
        }
        var merged = local
        for (field, remoteClock) in remote.clocks where remoteClock > (local.clocks[field] ?? "") {
            merged.clocks[field] = remoteClock
            merged.fields[field] = remote.fields[field] ?? .null
        }
        // Fields the remote has without a clock (written before tracking began) fill gaps only.
        for (field, value) in remote.fields where merged.fields[field] == nil {
            merged.fields[field] = value
        }
        return merged
    }

    /// The newest clock in the record.
    var latestClock: String {
        clocks.values.max() ?? ""
    }
}

// MARK: - Models as fields

enum RecordCoding {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    /// Set-valued fields, sorted so that equal sets compare equal.
    static let setFields: Set<String> = ["tagIDs"]

    static func fields<T: Encodable>(of model: T) throws -> [String: JSONValue] {
        var fields = try decoder.decode([String: JSONValue].self, from: encoder.encode(model))
        for key in setFields {
            if case .array(let items)? = fields[key] {
                fields[key] = .array(items.sorted { $0.sortKey < $1.sortKey })
            }
        }
        return fields
    }

    static func model<T: Decodable>(_ type: T.Type, from fields: [String: JSONValue]) throws -> T {
        try decoder.decode(T.self, from: encoder.encode(JSONValue.object(fields)))
    }

    /// Names of fields whose values differ. A field missing on one side counts as `null`.
    static func changedFields(_ old: [String: JSONValue]?, _ new: [String: JSONValue]) -> [String] {
        guard let old else { return Array(new.keys) }
        return Set(old.keys).union(new.keys).filter { (old[$0] ?? .null) != (new[$0] ?? .null) }.sorted()
    }
}

private extension JSONValue {
    var sortKey: String {
        switch self {
        case .string(let s): s
        case .number(let n): String(n)
        default: String(describing: self)
        }
    }
}

/// The current fields of every row in a database, by entity and id.
struct FieldSnapshot {
    var rows: [Entity: [UUID: [String: JSONValue]]] = [:]

    init(_ db: TaskDatabase) throws {
        rows[.area] = try Self.map(db.areas)
        rows[.tag] = try Self.map(db.tags)
        rows[.project] = try Self.map(db.projects)
        rows[.heading] = try Self.map(db.headings)
        rows[.todo] = try Self.map(db.todos)
    }

    private static func map<T: Encodable>(_ items: [UUID: T]) throws -> [UUID: [String: JSONValue]] {
        try items.mapValues(RecordCoding.fields(of:))
    }

    subscript(entity: Entity, id: UUID) -> [String: JSONValue]? {
        rows[entity]?[id]
    }
}

/// Rebuilds a database from per-entity field dictionaries.
enum RecordAssembly {
    static func database(from rows: [Entity: [UUID: [String: JSONValue]]]) throws -> TaskDatabase {
        func models<T: Decodable>(_ entity: Entity, _ type: T.Type) throws -> [T] {
            try (rows[entity] ?? [:]).values.map { try RecordCoding.model(T.self, from: $0) }
        }
        return TaskDatabase(todos: try models(.todo, Todo.self), projects: try models(.project, Project.self),
                            headings: try models(.heading, Heading.self), areas: try models(.area, Area.self),
                            tags: try models(.tag, Tag.self))
    }

    /// Clears references to rows that no longer exist (a heading deleted on another device while
    /// a to-do was moved under it here), so the database stays consistent after a merge.
    static func repaired(_ db: TaskDatabase) -> TaskDatabase {
        let headings = db.headings.values.filter { db.projects[$0.projectID] != nil }
        let headingIDs = Set(headings.map(\.id))
        let projects = db.projects.values.map { project -> Project in
            var project = project
            if let area = project.areaID, db.areas[area] == nil { project.areaID = nil }
            project.tagIDs = project.tagIDs.filter { db.tags[$0] != nil }
            return project
        }
        let areas = db.areas.values.map { area -> Area in
            var area = area
            area.tagIDs = area.tagIDs.filter { db.tags[$0] != nil }
            return area
        }
        let tags = db.tags.values.map { tag -> Tag in
            var tag = tag
            if let parent = tag.parentID, db.tags[parent] == nil { tag.parentID = nil }
            return tag
        }
        let todos = db.todos.values.map { todo -> Todo in
            var todo = todo
            if let project = todo.projectID, db.projects[project] == nil { todo.projectID = nil }
            if let area = todo.areaID, db.areas[area] == nil { todo.areaID = nil }
            if let heading = todo.headingID, !headingIDs.contains(heading) || todo.projectID == nil { todo.headingID = nil }
            todo.tagIDs = todo.tagIDs.filter { db.tags[$0] != nil }
            return todo
        }
        return TaskDatabase(todos: todos, projects: projects, headings: headings, areas: areas, tags: tags)
    }
}
