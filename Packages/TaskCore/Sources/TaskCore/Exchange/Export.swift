import Foundation

/// Daybook's own export formats: a complete JSON backup (which Daybook can import again), and a
/// CSV of to-dos for spreadsheets and other apps.
public enum DaybookExport {
    /// Identifies a Daybook backup file.
    public static let format = "daybook-backup"
    public static let version = 1

    struct Backup: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var data: TaskDatabase
    }

    static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    /// Everything, including completed and trashed items, as readable JSON.
    public static func json(_ db: TaskDatabase, exportedAt: Date = Date()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Dates stay in Foundation's own form (seconds since 2001) so a restore is exact.
        return try encoder.encode(Backup(format: format, version: version, exportedAt: exportedAt, data: db))
    }

    /// Reads a backup made by `json(_:)`.
    public static func readBackup(_ data: Data) throws -> TaskDatabase {
        struct Header: Decodable {
            var format: String?
            var version: Int?
        }
        let header = try? JSONDecoder().decode(Header.self, from: data)
        guard header?.format == format else { throw ImportError.unrecognized }
        guard (header?.version ?? 0) <= version else { throw ImportError.newerBackup }
        return try JSONDecoder().decode(Backup.self, from: data).data
    }

    public static let csvColumns = ["Title", "Notes", "Status", "When", "This Evening", "Deadline", "Reminder",
                                    "Area", "Project", "Heading", "Tags", "Checklist", "Repeats", "Created", "Completed"]

    /// One row per to-do (not trashed), open ones first, each in list order.
    public static func csv(_ db: TaskDatabase) -> String {
        let todos = db.todos.values
            .filter { !$0.isDeleted }
            .sorted { ($0.status.isClosed ? 1 : 0, $0.projectID?.uuidString ?? "", $0.order) < ($1.status.isClosed ? 1 : 0, $1.projectID?.uuidString ?? "", $1.order) }
        let rows = todos.map { todo -> [String] in
            let project = todo.projectID.flatMap { db.projects[$0] }
            let areaID = todo.areaID ?? project?.areaID
            return [
                todo.title,
                todo.notes,
                todo.status.rawValue,
                whenText(todo.when),
                todo.isEvening ? "yes" : "",
                todo.deadline?.description ?? "",
                todo.reminder?.description ?? "",
                areaID.flatMap { db.areas[$0]?.title } ?? "",
                project?.title ?? "",
                todo.headingID.flatMap { db.headings[$0]?.title } ?? "",
                todo.tagIDs.compactMap { db.tags[$0]?.title }.sorted().joined(separator: ", "),
                todo.checklist.map { ($0.isDone ? "[x] " : "[ ] ") + $0.title }.joined(separator: "\n"),
                todo.repetition?.rule.summary ?? "",
                timestamp(todo.createdAt),
                todo.completedAt.map(timestamp) ?? "",
            ]
        }
        return CSV.write([csvColumns] + rows)
    }

    static func whenText(_ when: When) -> String {
        switch when {
        case .inbox: "Inbox"
        case .anytime: "Anytime"
        case .someday: "Someday"
        case .on(let day): day.description
        }
    }
}

extension RepeatRule {
    /// A short English description, e.g. "Every 2 weeks on Mon, Thu" or "Every day after completion".
    public var summary: String {
        let unit: String
        var detail = ""
        switch frequency {
        case .daily:
            unit = "day"
        case .weekly(let days):
            unit = "week"
            let names = (days.isEmpty ? [anchor.weekday] : days.sorted()).map(\.shortName)
            detail = " on " + names.joined(separator: ", ")
        case .monthly(.day(let n)):
            unit = "month"
            detail = n == -1 ? " on the last day" : " on day \(n)"
        case .monthly(.weekday(let ordinal, let weekday)):
            unit = "month"
            let ordinals = [1: "first", 2: "second", 3: "third", 4: "fourth", 5: "fifth", -1: "last"]
            detail = " on the \(ordinals[ordinal] ?? "\(ordinal)th") \(weekday.shortName)"
        case .yearly(let month, let day):
            unit = "year"
            detail = " on \(month)/\(day)"
        }
        var text = interval == 1 ? "Every \(unit)" : "Every \(interval) \(unit)s"
        text += mode == .afterCompletion ? " after completion" : detail
        switch end {
        case .never: break
        case .until(let day): text += ", until \(day)"
        case .count(let n): text += ", \(n) times"
        }
        return text
    }
}

extension Weekday {
    var shortName: String {
        ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][rawValue - 1]
    }
}
