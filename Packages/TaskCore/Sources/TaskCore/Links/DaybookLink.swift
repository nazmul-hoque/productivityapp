import Foundation

/// The `daybook://` links the app understands, for automation (Shortcuts, other apps, the
/// widget and Siri all go through these).
///
/// - `daybook://today` (any smart list: inbox, today, upcoming, anytime, someday, logbook, trash)
/// - `daybook://add?title=Call%20Sam%20tomorrow%20at%205pm&notes=…&when=evening` adds a to-do
///   without asking; the title is read like quick add. `when` (inbox, today, evening, tomorrow,
///   anytime, someday) is used when the title gives no date.
/// - `daybook://new?title=…` opens quick add, optionally filled in
/// - `daybook://search?query=…` opens Quick Find
/// - `daybook://todo/<id>` opens a to-do
public enum DaybookLink: Equatable, Sendable {
    case show(SmartList)
    case add(title: String, notes: String?, when: AddWhen?)
    case newTodo(prefill: String?)
    case search(String)
    case todo(UUID)

    /// Where `add` puts a to-do whose title doesn't say.
    public enum AddWhen: String, CaseIterable, Sendable {
        case inbox, today, evening, tomorrow, anytime, someday
    }

    public static let scheme = "daybook"

    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        func query(_ name: String) -> String? {
            components.queryItems?.first { $0.name.lowercased() == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let host = (url.host ?? "").lowercased()
        switch host {
        case "add":
            guard let title = query("title") ?? query("text"), !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            self = .add(title: title, notes: query("notes"), when: query("when").flatMap { AddWhen(rawValue: $0.lowercased()) })
        case "new":
            self = .newTodo(prefill: query("title") ?? query("text"))
        case "search":
            self = .search(query("query") ?? query("q") ?? "")
        case "todo":
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            self = .todo(id)
        case "show":
            guard let list = query("list").flatMap({ SmartList(rawValue: $0.lowercased()) }) else { return nil }
            self = .show(list)
        default:
            guard let list = SmartList(rawValue: host) else { return nil }
            self = .show(list)
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .show(let list):
            components.host = list.rawValue
        case .add(let title, let notes, let when):
            components.host = "add"
            components.queryItems = [URLQueryItem(name: "title", value: title)]
                + (notes.map { [URLQueryItem(name: "notes", value: $0)] } ?? [])
                + (when.map { [URLQueryItem(name: "when", value: $0.rawValue)] } ?? [])
        case .newTodo(let prefill):
            components.host = "new"
            components.queryItems = prefill.map { [URLQueryItem(name: "title", value: $0)] }
        case .search(let query):
            components.host = "search"
            components.queryItems = [URLQueryItem(name: "query", value: query)]
        case .todo(let id):
            components.host = "todo"
            components.path = "/" + id.uuidString
        }
        return components.url!
    }
}

extension TaskDatabase {
    /// Adds a to-do as `daybook://add` (and Siri) do: the title is read like quick add; `when`
    /// applies if it gives no date.
    @discardableResult
    public mutating func add(title: String, notes: String?, when: DaybookLink.AddWhen?, today: LocalDay, now: Date = Date()) -> Todo {
        var parsed = QuickAddParser(today: today).parse(title)
        let defaultWhen: When
        switch when {
        case .today, .evening: defaultWhen = .on(today)
        case .tomorrow: defaultWhen = .on(today.adding(days: 1))
        case .anytime: defaultWhen = .anytime
        case .someday: defaultWhen = .someday
        case .inbox, nil: defaultWhen = .inbox
        }
        if parsed.when == nil && when == .evening { parsed.isEvening = true }
        var todo = add(parsed, defaultWhen: defaultWhen, today: today, now: now)
        if let notes, !notes.isEmpty {
            modify(todo.id, now: now) { $0.notes = notes }
            todo.notes = notes
        }
        return todo
    }
}
