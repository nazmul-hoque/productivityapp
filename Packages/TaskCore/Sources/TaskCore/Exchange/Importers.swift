import Foundation

// MARK: - Todoist

/// Todoist's project export (*Project → ⋯ → Export as a template → Download CSV*): one file per
/// project, with sections, tasks, sub-tasks (by INDENT) and comments ("note" rows).
public enum TodoistImport {
    public static func database(fromCSV text: String, projectName: String, today: LocalDay) throws -> TaskDatabase {
        guard let table = CSVTable(text, headerContaining: "CONTENT") else { throw ImportError.unrecognized }
        var db = TaskDatabase()
        let project = db.addProject(Project(title: projectName))
        var heading: Heading?
        var lastTop: UUID?
        var lastTask: UUID?

        for row in table.rows {
            let content = table.value("CONTENT", in: row)
            switch table.value("TYPE", in: row).lowercased() {
            case "section":
                guard !content.isEmpty else { continue }
                heading = db.addHeading(content, toProject: project.id)
                lastTop = nil
            case "task":
                let (title, labels) = ImportText.extractingLabels(content)
                guard !title.isEmpty else { continue }
                let indent = Int(table.value("INDENT", in: row)) ?? 1
                if indent > 1, let parent = lastTop {
                    db.modify(parent) { $0.checklist.append(ChecklistItem(title: title)) }
                    continue
                }
                var tags = labels.map { db.tag(named: $0).id }
                // Todoist's p1 is PRIORITY 4 in the file.
                switch table.value("PRIORITY", in: row) {
                case "4": tags.append(db.tag(named: "Priority 1").id)
                case "3": tags.append(db.tag(named: "Priority 2").id)
                case "2": tags.append(db.tag(named: "Priority 3").id)
                default: break
                }
                var todo = Todo(title: title, notes: table.value("DESCRIPTION", in: row), projectID: project.id,
                                headingID: heading?.id, when: .anytime, tagIDs: Set(tags))
                let date = table.value("DATE", in: row)
                if !date.isEmpty {
                    if let rule = RecurrenceText.rule(from: date, today: today) {
                        todo.when = .on(rule.anchor)
                        todo.repetition = Repetition(rule: rule, occurrence: rule.anchor)
                        // "every monday at 9am": keep the time as the reminder.
                        let time = date.range(of: " at ").map { String(date[$0.upperBound...]) }
                        todo.reminder = time.flatMap { ImportText.when(from: "today at \($0)", today: today)?.time }
                    } else if let (day, time) = ImportText.when(from: date, today: today) {
                        todo.when = .on(day)
                        todo.reminder = time
                    } else {
                        todo.notes = ImportText.appendingLine("Date in Todoist: \(date)", to: todo.notes)
                    }
                }
                let deadline = table.value("DEADLINE", in: row)
                if !deadline.isEmpty { todo.deadline = ImportText.when(from: deadline, today: today)?.day }
                let added = db.add(todo, today: today)
                lastTop = added.id
                lastTask = added.id
            case "note":
                guard let task = lastTask, !content.isEmpty else { continue }
                db.modify(task) { $0.notes = ImportText.appendingLine(content, to: $0.notes) }
            default:
                continue
            }
        }
        return db
    }
}

// MARK: - TickTick

/// TickTick's backup (*Settings → Account → Generate Backup*): a CSV of every list, after a few
/// lines of notes. Folders become areas, lists projects (except the Inbox), kanban columns
/// headings, and sub-tasks checklist items.
public enum TickTickImport {
    public static func database(fromCSV text: String, timeZone: TimeZone = .current) throws -> TaskDatabase {
        guard let table = CSVTable(text, headerContaining: "List Name") else { throw ImportError.unrecognized }
        var db = TaskDatabase()
        var areas: [String: UUID] = [:]
        var projects: [String: UUID] = [:]
        var headings: [String: UUID] = [:]
        var tasks: [String: UUID] = [:]
        var children: [(parent: String, row: [String])] = []

        for row in table.rows {
            let title = table.value("Title", in: row)
            guard !title.isEmpty else { continue }
            let parent = table.value("parentId", in: row)
            if !parent.isEmpty {
                children.append((parent, row))
                continue
            }
            let zone = TimeZone(identifier: table.value("Timezone", in: row)) ?? timeZone

            var areaID: UUID?
            let folder = table.value("Folder Name", in: row)
            if !folder.isEmpty {
                areaID = areas[folder] ?? db.addArea(folder).id
                areas[folder] = areaID
            }
            var projectID: UUID?
            let list = table.value("List Name", in: row)
            if !list.isEmpty && list.lowercased() != "inbox" {
                projectID = projects[list] ?? db.addProject(Project(title: list, areaID: areaID)).id
                projects[list] = projectID
            }
            var headingID: UUID?
            let column = table.value("Column Name", in: row)
            if let projectID, !column.isEmpty {
                let key = "\(projectID)/\(column)"
                headingID = headings[key] ?? db.addHeading(column, toProject: projectID).id
                headings[key] = headingID
            }

            let isAllDay = table.value("Is All Day", in: row).lowercased() != "false"
            let start = date(table.value("Start Date", in: row))
            let due = date(table.value("Due Date", in: row))
            let created = date(table.value("Created Time", in: row)) ?? Date()
            var todo = Todo(title: title, areaID: projectID == nil ? areaID : nil, projectID: projectID, headingID: headingID,
                            when: projectID == nil && areaID == nil ? .inbox : .anytime, createdAt: created)
            // TickTick's date is when you plan to do it; a later due date (a range) becomes the deadline.
            if let planned = start ?? due {
                let day = LocalDay(planned, timeZone: zone)
                todo.when = .on(day)
                if !isAllDay { todo.reminder = time(planned, zone) }
                if start != nil, let due, LocalDay(due, timeZone: zone) > day { todo.deadline = LocalDay(due, timeZone: zone) }
                let repeatText = table.value("Repeat", in: row)
                if !repeatText.isEmpty, let rule = RRule.rule(from: repeatText, anchor: day) {
                    todo.repetition = Repetition(rule: rule, occurrence: day)
                }
            }
            let content = table.value("Content", in: row)
            if table.value("Is Check list", in: row).uppercased() == "Y" {
                todo.checklist = checklist(from: content)
            } else {
                todo.notes = content
            }
            todo.tagIDs = Set(table.value("Tags", in: row).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
                .filter { !$0.isEmpty }
                .map { db.tag(named: $0).id })
            if table.value("Status", in: row) != "0" && !table.value("Status", in: row).isEmpty {
                todo.status = .completed
                todo.completedAt = date(table.value("Completed Time", in: row)) ?? created
            }
            tasks[table.value("taskId", in: row)] = db.add(todo, today: LocalDay(Date(), timeZone: zone)).id
        }

        for (parent, row) in children {
            guard let parentID = tasks[parent] else { continue }
            let item = ChecklistItem(title: table.value("Title", in: row), isDone: table.value("Status", in: row) != "0")
            db.modify(parentID) { $0.checklist.append(item) }
        }
        return db
    }

    /// "2026-10-14T16:00:00+0000".
    static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: text)
    }

    static func time(_ date: Date, _ zone: TimeZone) -> TimeOfDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return TimeOfDay(hour: c.hour ?? 9, minute: c.minute ?? 0)
    }

    /// Checklist lines, with TickTick's (and Markdown's) done/not-done markers.
    static func checklist(from content: String) -> [ChecklistItem] {
        content.split(whereSeparator: \.isNewline).compactMap { line in
            var text = line.trimmingCharacters(in: .whitespaces)
            var done = false
            for (marker, isDone) in [("- [x]", true), ("- [X]", true), ("- [ ]", false), ("▪", true), ("☑", true),
                                     ("✓", true), ("✔", true), ("▫", false), ("☐", false), ("-", false)]
            where text.hasPrefix(marker) {
                text = String(text.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                done = isDone
                break
            }
            return text.isEmpty ? nil : ChecklistItem(title: text, isDone: done)
        }
    }
}

// MARK: - Google Tasks

/// Tasks.json from Google Takeout (takeout.google.com → Tasks): each list becomes a project;
/// sub-tasks become checklist items.
public enum GoogleTasksImport {
    struct File: Decodable {
        var items: [List]?
    }

    struct List: Decodable {
        var title: String?
        var items: [Task]?
    }

    struct Task: Decodable {
        var id: String?
        var title: String?
        var notes: String?
        var status: String?
        var due: String?
        var completed: String?
        var updated: String?
        var parent: String?
        var position: String?
        var deleted: Bool?
    }

    public static func database(fromJSON data: Data) throws -> TaskDatabase {
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw ImportError.unreadable(String(describing: error))
        }
        var db = TaskDatabase()
        let today = LocalDay(Date())
        for list in file.items ?? [] {
            let tasks = (list.items ?? []).filter { $0.deleted != true && !($0.title ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
                .sorted { ($0.position ?? "") < ($1.position ?? "") }
            guard !tasks.isEmpty else { continue }
            let project = db.addProject(Project(title: list.title?.isEmpty == false ? list.title! : "Google Tasks"))
            var ids: [String: UUID] = [:]
            for task in tasks where task.parent == nil {
                var todo = Todo(title: task.title!.trimmingCharacters(in: .whitespaces), notes: task.notes ?? "",
                                projectID: project.id, when: .anytime)
                // Google keeps only the date of a due date, at midnight UTC.
                if let due = task.due, let day = LocalDay(iso: String(due.prefix(10))) { todo.when = .on(day) }
                if task.status == "completed" {
                    todo.status = .completed
                    todo.completedAt = task.completed.flatMap(parseDate) ?? Date()
                }
                if let id = task.id { ids[id] = db.add(todo, today: today).id } else { db.add(todo, today: today) }
            }
            for task in tasks {
                guard let parent = task.parent, let parentID = ids[parent] else { continue }
                let item = ChecklistItem(title: task.title!.trimmingCharacters(in: .whitespaces), isDone: task.status == "completed")
                db.modify(parentID) { $0.checklist.append(item) }
            }
        }
        return db
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// MARK: - Apple Reminders

/// A reminder as read from EventKit by the app (EventKit itself isn't available here).
public struct ReminderItem: Sendable, Equatable {
    public var title: String
    public var notes: String
    public var listName: String
    public var url: URL?
    public var day: LocalDay?
    /// Set when the reminder has a time, not just a day.
    public var time: TimeOfDay?
    public var repeatRule: RepeatRule?
    public var isCompleted: Bool
    public var completedAt: Date?
    public var createdAt: Date?

    public init(title: String, notes: String = "", listName: String, url: URL? = nil, day: LocalDay? = nil,
                time: TimeOfDay? = nil, repeatRule: RepeatRule? = nil, isCompleted: Bool = false,
                completedAt: Date? = nil, createdAt: Date? = nil) {
        self.title = title
        self.notes = notes
        self.listName = listName
        self.url = url
        self.day = day
        self.time = time
        self.repeatRule = repeatRule
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.createdAt = createdAt
    }
}

/// Reminders lists become projects; dated reminders are scheduled for their day, with their
/// time as the to-do's reminder.
public enum RemindersImport {
    public static func database(from items: [ReminderItem], today: LocalDay) -> TaskDatabase {
        var db = TaskDatabase()
        var projects: [String: UUID] = [:]
        for item in items {
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let projectID = projects[item.listName] ?? db.addProject(Project(title: item.listName.isEmpty ? "Reminders" : item.listName)).id
            projects[item.listName] = projectID
            var todo = Todo(title: title, notes: item.notes, projectID: projectID, when: .anytime, createdAt: item.createdAt ?? Date())
            if let url = item.url { todo.notes = ImportText.appendingLine(url.absoluteString, to: todo.notes) }
            if let day = item.day {
                todo.when = .on(day)
                todo.reminder = item.time
                if var rule = item.repeatRule {
                    rule.anchor = day
                    rule.reminder = item.time
                    todo.repetition = Repetition(rule: rule, occurrence: day)
                }
            }
            if item.isCompleted {
                todo.status = .completed
                todo.completedAt = item.completedAt ?? Date()
            }
            db.add(todo, today: today)
        }
        return db
    }
}
