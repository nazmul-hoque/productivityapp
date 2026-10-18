import Foundation
import GRDB
import TaskCore

/// Conversions between TaskCore models and table rows.
///
/// Mapping is written out by hand: the tables are shaped for SQL and sync (snake_case,
/// join tables, flattened `When`), which differs from the in-memory models.
enum Rows {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    // MARK: - Writing

    static func upsert(_ area: Area, now: Date, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO area (id, title, sort_key, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, sort_key = excluded.sort_key,
                updated_at = excluded.updated_at
            """, arguments: [area.id.uuidString, area.title, area.order, ts(now), ts(now)])
        try replaceTags(area.tagIDs, table: "area_tag", column: "area_id", owner: area.id, in: db)
    }

    static func upsert(_ tag: Tag, now: Date, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO tag (id, parent_id, title, sort_key, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET parent_id = excluded.parent_id, title = excluded.title,
                sort_key = excluded.sort_key, updated_at = excluded.updated_at
            """, arguments: [tag.id.uuidString, tag.parentID?.uuidString, tag.title, tag.order, ts(now), ts(now)])
    }

    static func upsert(_ project: Project, in db: Database) throws {
        let start = StartColumns(project.when)
        let rule = try project.repetition.map { String(decoding: try encoder.encode($0.rule), as: UTF8.self) }
        try db.execute(sql: """
            INSERT INTO project (id, area_id, title, notes, start_bucket, start_date, deadline,
                                 repeat_series_id, repeat_rule, repeat_occurrence, repeat_index, status, sort_key,
                                 created_at, updated_at, completed_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET area_id = excluded.area_id, title = excluded.title, notes = excluded.notes,
                start_bucket = excluded.start_bucket, start_date = excluded.start_date, deadline = excluded.deadline,
                repeat_series_id = excluded.repeat_series_id, repeat_rule = excluded.repeat_rule,
                repeat_occurrence = excluded.repeat_occurrence, repeat_index = excluded.repeat_index,
                status = excluded.status, sort_key = excluded.sort_key, updated_at = excluded.updated_at,
                completed_at = excluded.completed_at, deleted_at = excluded.deleted_at
            """, arguments: [
                project.id.uuidString, project.areaID?.uuidString, project.title, project.notes,
                start.bucket, start.date, project.deadline?.description,
                project.repetition?.seriesID.uuidString, rule, project.repetition?.occurrence.description, project.repetition?.index,
                project.status.rawValue, project.order,
                ts(project.createdAt), ts(project.updatedAt), ts(project.completedAt), ts(project.deletedAt),
            ])
        try replaceTags(project.tagIDs, table: "project_tag", column: "project_id", owner: project.id, in: db)
    }

    static func upsert(_ heading: Heading, now: Date, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO heading (id, project_id, title, sort_key, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET project_id = excluded.project_id, title = excluded.title,
                sort_key = excluded.sort_key, updated_at = excluded.updated_at
            """, arguments: [heading.id.uuidString, heading.projectID.uuidString, heading.title, heading.order, ts(now), ts(now)])
    }

    static func upsert(_ todo: Todo, in db: Database) throws {
        let start = StartColumns(todo.when)
        let rule = try todo.repetition.map { String(decoding: try encoder.encode($0.rule), as: UTF8.self) }
        try db.execute(sql: """
            INSERT INTO todo (id, area_id, project_id, heading_id, title, notes, start_bucket, start_date, is_evening,
                              deadline, reminder, repeat_series_id, repeat_rule, repeat_occurrence, repeat_index,
                              status, sort_key, today_sort_key, created_at, updated_at, completed_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET area_id = excluded.area_id, project_id = excluded.project_id,
                heading_id = excluded.heading_id, title = excluded.title, notes = excluded.notes,
                start_bucket = excluded.start_bucket, start_date = excluded.start_date, is_evening = excluded.is_evening,
                deadline = excluded.deadline, reminder = excluded.reminder, repeat_series_id = excluded.repeat_series_id,
                repeat_rule = excluded.repeat_rule, repeat_occurrence = excluded.repeat_occurrence,
                repeat_index = excluded.repeat_index, status = excluded.status, sort_key = excluded.sort_key,
                today_sort_key = excluded.today_sort_key, updated_at = excluded.updated_at,
                completed_at = excluded.completed_at, deleted_at = excluded.deleted_at
            """, arguments: [
                todo.id.uuidString, todo.areaID?.uuidString, todo.projectID?.uuidString, todo.headingID?.uuidString,
                todo.title, todo.notes, start.bucket, start.date, todo.isEvening,
                todo.deadline?.description, todo.reminder?.description,
                todo.repetition?.seriesID.uuidString, rule, todo.repetition?.occurrence.description, todo.repetition?.index,
                todo.status.rawValue, todo.order, todo.todayOrder,
                ts(todo.createdAt), ts(todo.updatedAt), ts(todo.completedAt), ts(todo.deletedAt),
            ])

        try db.execute(sql: "DELETE FROM checklist_item WHERE todo_id = ?", arguments: [todo.id.uuidString])
        for (position, item) in todo.checklist.enumerated() {
            try db.execute(sql: "INSERT INTO checklist_item (id, todo_id, title, is_done, position) VALUES (?, ?, ?, ?, ?)",
                           arguments: [item.id.uuidString, todo.id.uuidString, item.title, item.isDone, position])
        }
        try replaceTags(todo.tagIDs, table: "todo_tag", column: "todo_id", owner: todo.id, in: db)
    }

    static func delete(from table: String, id: UUID, in db: Database) throws {
        try db.execute(sql: "DELETE FROM \(table) WHERE id = ?", arguments: [id.uuidString])
    }

    private static func replaceTags(_ tagIDs: Set<UUID>, table: String, column: String, owner: UUID, in db: Database) throws {
        try db.execute(sql: "DELETE FROM \(table) WHERE \(column) = ?", arguments: [owner.uuidString])
        for tagID in tagIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            try db.execute(sql: "INSERT INTO \(table) (\(column), tag_id) VALUES (?, ?)",
                           arguments: [owner.uuidString, tagID.uuidString])
        }
    }

    // MARK: - Reading

    static func loadAll(_ db: Database) throws -> TaskDatabase {
        let areaTags = try tagMap(db, table: "area_tag", column: "area_id")
        let projectTags = try tagMap(db, table: "project_tag", column: "project_id")
        let todoTags = try tagMap(db, table: "todo_tag", column: "todo_id")

        var checklists: [UUID: [ChecklistItem]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM checklist_item ORDER BY todo_id, position") {
            let item = ChecklistItem(id: try uuid(row, "id"), title: row["title"], isDone: row["is_done"])
            checklists[try uuid(row, "todo_id"), default: []].append(item)
        }

        let areas = try Row.fetchAll(db, sql: "SELECT * FROM area").map { row in
            let id = try uuid(row, "id")
            return Area(id: id, title: row["title"], tagIDs: areaTags[id] ?? [], order: row["sort_key"])
        }
        let tags = try Row.fetchAll(db, sql: "SELECT * FROM tag").map { row in
            Tag(id: try uuid(row, "id"), title: row["title"], parentID: try optionalUUID(row, "parent_id"),
                order: row["sort_key"])
        }
        let headings = try Row.fetchAll(db, sql: "SELECT * FROM heading").map { row in
            Heading(id: try uuid(row, "id"), projectID: try uuid(row, "project_id"), title: row["title"],
                    order: row["sort_key"])
        }
        let projects = try Row.fetchAll(db, sql: "SELECT * FROM project").map { row in
            let id = try uuid(row, "id")
            return Project(
                id: id, title: row["title"], notes: row["notes"], areaID: try optionalUUID(row, "area_id"),
                when: try when(row), deadline: try day(row, "deadline"), repetition: try repetition(row), tagIDs: projectTags[id] ?? [],
                status: try status(row), order: row["sort_key"], createdAt: date(row, "created_at")!,
                updatedAt: date(row, "updated_at"), completedAt: date(row, "completed_at"), deletedAt: date(row, "deleted_at"))
        }
        let todos = try Row.fetchAll(db, sql: "SELECT * FROM todo").map { row in
            let id = try uuid(row, "id")
            return Todo(
                id: id, title: row["title"], notes: row["notes"], areaID: try optionalUUID(row, "area_id"),
                projectID: try optionalUUID(row, "project_id"), headingID: try optionalUUID(row, "heading_id"),
                when: try when(row), isEvening: row["is_evening"], deadline: try day(row, "deadline"),
                reminder: try time(row, "reminder"), repetition: try repetition(row), tagIDs: todoTags[id] ?? [],
                checklist: checklists[id] ?? [], status: try status(row), order: row["sort_key"],
                todayOrder: row["today_sort_key"], createdAt: date(row, "created_at")!, updatedAt: date(row, "updated_at"),
                completedAt: date(row, "completed_at"), deletedAt: date(row, "deleted_at"))
        }
        return TaskDatabase(todos: todos, projects: projects, headings: headings, areas: areas, tags: tags)
    }

    private static func tagMap(_ db: Database, table: String, column: String) throws -> [UUID: Set<UUID>] {
        var map: [UUID: Set<UUID>] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT \(column), tag_id FROM \(table)") {
            map[try uuid(row, column), default: []].insert(try uuid(row, "tag_id"))
        }
        return map
    }

    // MARK: - Column helpers

    /// Timestamps are stored as seconds since 2001-01-01 (REAL), `Date`'s own representation,
    /// so they round-trip exactly (converting to the 1970 epoch loses the last bits).
    static func ts(_ date: Date?) -> Double? { date?.timeIntervalSinceReferenceDate }

    static func date(_ row: Row, _ column: String) -> Date? {
        (row[column] as Double?).map(Date.init(timeIntervalSinceReferenceDate:))
    }

    struct StartColumns {
        var bucket: String
        var date: String?

        init(_ when: When) {
            switch when {
            case .inbox: bucket = "inbox"
            case .anytime: bucket = "anytime"
            case .someday: bucket = "someday"
            case .on(let day): bucket = "scheduled"; date = day.description
            }
        }
    }

    static func when(_ row: Row) throws -> When {
        let bucket: String = row["start_bucket"]
        switch bucket {
        case "inbox": return .inbox
        case "anytime": return .anytime
        case "someday": return .someday
        case "scheduled":
            guard let day = try day(row, "start_date") else { throw StoreError.corrupt("scheduled without start_date") }
            return .on(day)
        default: throw StoreError.corrupt("unknown start_bucket \(bucket)")
        }
    }

    static func status(_ row: Row) throws -> ItemStatus {
        let raw: String = row["status"]
        guard let status = ItemStatus(rawValue: raw) else { throw StoreError.corrupt("unknown status \(raw)") }
        return status
    }

    static func uuid(_ row: Row, _ column: String) throws -> UUID {
        guard let id = try optionalUUID(row, column) else { throw StoreError.corrupt("missing \(column)") }
        return id
    }

    static func optionalUUID(_ row: Row, _ column: String) throws -> UUID? {
        guard let string: String = row[column] else { return nil }
        guard let id = UUID(uuidString: string) else { throw StoreError.corrupt("bad uuid in \(column): \(string)") }
        return id
    }

    static func day(_ row: Row, _ column: String) throws -> LocalDay? {
        guard let string: String = row[column] else { return nil }
        guard let day = LocalDay(iso: string) else { throw StoreError.corrupt("bad day in \(column): \(string)") }
        return day
    }

    static func time(_ row: Row, _ column: String) throws -> TimeOfDay? {
        guard let string: String = row[column] else { return nil }
        let parts = string.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else {
            throw StoreError.corrupt("bad time in \(column): \(string)")
        }
        return TimeOfDay(hour: parts[0], minute: parts[1])
    }

    static func repetition(_ row: Row) throws -> Repetition? {
        guard let json: String = row["repeat_rule"] else { return nil }
        let rule = try JSONDecoder().decode(RepeatRule.self, from: Data(json.utf8))
        guard let occurrence = try day(row, "repeat_occurrence") else { throw StoreError.corrupt("repeat without occurrence") }
        return Repetition(seriesID: try uuid(row, "repeat_series_id"), rule: rule, occurrence: occurrence,
                          index: row["repeat_index"] ?? 1)
    }
}

public enum StoreError: Error, CustomStringConvertible {
    case corrupt(String)

    public var description: String {
        switch self {
        case .corrupt(let detail): "Corrupt database row: \(detail)"
        }
    }
}
