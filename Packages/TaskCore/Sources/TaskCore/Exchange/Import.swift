import Foundation

public enum ImportError: Error, Equatable, CustomStringConvertible {
    case unrecognized
    case newerBackup
    case unreadable(String)

    public var description: String {
        switch self {
        case .unrecognized:
            "This file isn't one Daybook can import. Use a Daybook backup, a Todoist project CSV, a TickTick backup CSV, or Tasks.json from Google Takeout."
        case .newerBackup:
            "This backup was made by a newer version of Daybook. Update the app to import it."
        case .unreadable(let detail):
            "The file couldn't be read: \(detail)"
        }
    }
}

/// The files Daybook can import.
public enum ImportFormat: String, CaseIterable, Sendable {
    case daybook, todoist, tickTick, googleTasks

    public var displayName: String {
        switch self {
        case .daybook: "Daybook backup"
        case .todoist: "Todoist"
        case .tickTick: "TickTick"
        case .googleTasks: "Google Tasks"
        }
    }
}

public enum Importer {
    /// Recognizes a file by its contents.
    public static func detect(_ data: Data) -> ImportFormat? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if json["format"] as? String == DaybookExport.format { return .daybook }
            if (json["kind"] as? String)?.hasPrefix("tasks#") == true || json["items"] is [Any] { return .googleTasks }
            return nil
        }
        guard let text = decode(data) else { return nil }
        let head = CSV.parse(String(text.prefix(20_000))).prefix(40)
        if head.contains(where: { $0.contains("TYPE") && $0.contains("CONTENT") }) { return .todoist }
        if head.contains(where: { $0.contains("List Name") && $0.contains("Title") }) { return .tickTick }
        return nil
    }

    /// Reads a file into a new database, ready to `merge` into the user's.
    /// - Parameter fileName: used to name the project for Todoist, whose CSV is one project per file.
    public static func read(_ data: Data, fileName: String, today: LocalDay, timeZone: TimeZone = .current)
        throws -> (format: ImportFormat, database: TaskDatabase) {
        guard let format = detect(data) else { throw ImportError.unrecognized }
        switch format {
        case .daybook:
            return (format, try DaybookExport.readBackup(data))
        case .googleTasks:
            return (format, try GoogleTasksImport.database(fromJSON: data))
        case .todoist:
            let name = (fileName as NSString).deletingPathExtension
            return (format, try TodoistImport.database(fromCSV: decode(data) ?? "", projectName: name.isEmpty ? "Todoist" : name, today: today))
        case .tickTick:
            return (format, try TickTickImport.database(fromCSV: decode(data) ?? "", timeZone: timeZone))
        }
    }

    static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}

// MARK: - Merging

public struct ImportSummary: Equatable, Sendable {
    public var todos = 0
    public var projects = 0
    public var areas = 0
    public var tags = 0
    /// Items already here (importing the same backup twice).
    public var skipped = 0

    public init() {}
}

extension TaskDatabase {
    /// Adds an imported database to this one. Areas and tags with the same name (ignoring case)
    /// are reused rather than duplicated; items whose id already exists are skipped, so importing
    /// the same backup again adds nothing. New items go at the end of their lists, in order.
    @discardableResult
    public mutating func merge(_ imported: TaskDatabase, today: LocalDay) -> ImportSummary {
        var summary = ImportSummary()

        var tagIDs: [UUID: UUID] = [:]
        for tag in imported.sortedTags {
            let isNew = !tags.values.contains { $0.title.caseInsensitiveCompare(tag.title) == .orderedSame }
            tagIDs[tag.id] = self.tag(named: tag.title).id
            if isNew { summary.tags += 1 }
        }

        var areaIDs: [UUID: UUID] = [:]
        for area in imported.sortedAreas {
            if let existing = areas.values.first(where: { $0.title.caseInsensitiveCompare(area.title) == .orderedSame }) {
                areaIDs[area.id] = existing.id
            } else {
                areaIDs[area.id] = addArea(area.title).id
                summary.areas += 1
            }
        }

        for project in imported.projects.values.sorted(by: Self.byOrder) {
            if projects[project.id] != nil {
                summary.skipped += 1
                continue
            }
            var project = project
            project.areaID = project.areaID.flatMap { areaIDs[$0] }
            project.tagIDs = Set(project.tagIDs.compactMap { tagIDs[$0] })
            addProject(project)
            summary.projects += 1
        }

        var headingIDs: Set<UUID> = []
        for heading in imported.headings.values.sorted(by: Self.byOrder) where projects[heading.projectID] != nil {
            if headings[heading.id] == nil { insert(heading) }
            headingIDs.insert(heading.id)
        }

        let todos = imported.todos.values.sorted {
            ($0.projectID?.uuidString ?? "", $0.headingID?.uuidString ?? "", $0.order)
                < ($1.projectID?.uuidString ?? "", $1.headingID?.uuidString ?? "", $1.order)
        }
        for todo in todos {
            if self.todos[todo.id] != nil {
                summary.skipped += 1
                continue
            }
            var todo = todo
            if let project = todo.projectID, projects[project] == nil { todo.projectID = nil }
            todo.areaID = todo.areaID.flatMap { areaIDs[$0] }
            todo.headingID = todo.projectID == nil ? nil : todo.headingID.flatMap { headingIDs.contains($0) ? $0 : nil }
            todo.tagIDs = Set(todo.tagIDs.compactMap { tagIDs[$0] })
            todo.todayOrder = nil
            add(todo, today: today)
            summary.todos += 1
        }
        return summary
    }
}

// MARK: - Shared helpers

enum ImportText {
    /// "Buy milk @errands @home" → ("Buy milk", ["errands", "home"]).
    static func extractingLabels(_ text: String, prefix: Character = "@") -> (title: String, labels: [String]) {
        var labels: [String] = []
        var words: [Substring] = []
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if word.count > 1, word.first == prefix {
                labels.append(String(word.dropFirst()))
            } else {
                words.append(word)
            }
        }
        return (words.joined(separator: " "), labels)
    }

    /// A date phrase ("Oct 20", "tomorrow at 9am", "2026-10-20") read the way quick add reads it.
    static func when(from phrase: String, today: LocalDay) -> (day: LocalDay, time: TimeOfDay?)? {
        let parsed = QuickAddParser(today: today).parse("x " + phrase)
        guard case .on(let day)? = parsed.when else { return nil }
        return (day, parsed.reminder)
    }

    static func appendingLine(_ line: String, to notes: String) -> String {
        notes.isEmpty ? line : notes + "\n" + line
    }
}

/// Recurrence written in words, as Todoist exports it: "every day", "every 2 weeks",
/// "every mon, fri", "every weekday", "every 15th", "every! 3 days" (after completion).
enum RecurrenceText {
    static func rule(from text: String, today: LocalDay) -> RepeatRule? {
        var phrase = text.lowercased().trimmingCharacters(in: .whitespaces)
        for cut in [" at ", " starting ", " from ", " until ", " ending "] {
            if let range = phrase.range(of: cut) { phrase = String(phrase[..<range.lowerBound]) }
        }
        var mode = RepeatRule.Mode.fixed
        if phrase.hasPrefix("every!") {
            mode = .afterCompletion
            phrase = "every " + phrase.dropFirst(6)
        }
        switch phrase.trimmingCharacters(in: .whitespaces) {
        case "daily": phrase = "every day"
        case "weekly": phrase = "every week"
        case "monthly": phrase = "every month"
        case "yearly", "annually": phrase = "every year"
        default: break
        }
        guard phrase.hasPrefix("every ") else { return nil }
        var words = phrase.dropFirst(6).replacingOccurrences(of: ",", with: " ")
            .split(separator: " ").map(String.init).filter { $0 != "and" }
        var interval = 1
        if words.first == "other" {
            interval = 2
            words.removeFirst()
        } else if let n = words.first.flatMap({ Int($0) }) {
            interval = max(n, 1)
            words.removeFirst()
        }
        guard let unit = words.first else { return nil }

        func rule(_ frequency: RepeatRule.Frequency, anchor: LocalDay) -> RepeatRule {
            RepeatRule(frequency: frequency, interval: interval, mode: mode, anchor: anchor)
        }
        switch unit {
        case "day", "days":
            return rule(.daily, anchor: today)
        case "weekday", "weekdays", "workday", "workdays":
            let days: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
            return rule(.weekly(days), anchor: firstDay(in: days, from: today))
        case "week", "weeks":
            return rule(.weekly([]), anchor: today)
        case "month", "months":
            return rule(.monthly(.day(today.day)), anchor: today)
        case "year", "years":
            return rule(.yearly(month: today.month, day: today.day), anchor: today)
        default:
            let days = Set(words.compactMap(QuickAddParser.weekday))
            if !days.isEmpty {
                return rule(.weekly(days), anchor: firstDay(in: days, from: today))
            }
            if let n = QuickAddParser.dayOfMonth(unit) {
                var anchor = LocalDay(year: today.year, month: today.month, day: n)
                if anchor < today { anchor = anchor.adding(months: 1) }
                return rule(.monthly(.day(n)), anchor: anchor)
            }
            return nil
        }
    }

    static func firstDay(in days: Set<Weekday>, from today: LocalDay) -> LocalDay {
        days.map { today.next($0) }.min() ?? today
    }
}

/// iCalendar recurrence rules (`RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH`), as TickTick exports them.
enum RRule {
    static func rule(from text: String, anchor: LocalDay) -> RepeatRule? {
        var parts: [String: String] = [:]
        for pair in text.replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { parts[kv[0].uppercased()] = String(kv[1]) }
        }
        let interval = max(Int(parts["INTERVAL"] ?? "1") ?? 1, 1)
        let codes = ["MO": Weekday.monday, "TU": .tuesday, "WE": .wednesday, "TH": .thursday, "FR": .friday, "SA": .saturday, "SU": .sunday]
        let byDay = (parts["BYDAY"] ?? "").split(separator: ",").map(String.init)
        var end = RepeatRule.End.never
        if let count = parts["COUNT"].flatMap(Int.init) { end = .count(count) }
        if let until = parts["UNTIL"], until.count >= 8, let day = LocalDay(iso: "\(until.prefix(4))-\(until.dropFirst(4).prefix(2))-\(until.dropFirst(6).prefix(2))") {
            end = .until(day)
        }
        let frequency: RepeatRule.Frequency
        switch parts["FREQ"]?.uppercased() {
        case "DAILY":
            frequency = .daily
        case "WEEKLY":
            frequency = .weekly(Set(byDay.compactMap { codes[String($0.suffix(2))] }))
        case "MONTHLY":
            if let first = byDay.first, let weekday = codes[String(first.suffix(2))] {
                let ordinal = Int(first.dropLast(2)) ?? 1
                frequency = .monthly(.weekday(ordinal: ordinal, weekday))
            } else {
                frequency = .monthly(.day(Int(parts["BYMONTHDAY"] ?? "") ?? anchor.day))
            }
        case "YEARLY":
            frequency = .yearly(month: anchor.month, day: anchor.day)
        default:
            return nil
        }
        return RepeatRule(frequency: frequency, interval: interval, end: end, anchor: anchor)
    }
}
