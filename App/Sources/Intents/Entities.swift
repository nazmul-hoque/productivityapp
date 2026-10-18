import AppIntents
import Foundation
import TaskCore

/// A to-do, for Shortcuts and Siri.
struct TodoEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "To-Do"
    static let defaultQuery = TodoQuery()

    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Notes") var notes: String
    @Property(title: "Completed") var isCompleted: Bool
    let detail: String

    init(_ todo: Todo, in db: TaskDatabase) {
        id = todo.id
        detail = Self.detail(for: todo, in: db)
        title = todo.title
        notes = todo.notes
        isCompleted = todo.status.isClosed
    }

    var displayRepresentation: DisplayRepresentation {
        detail.isEmpty ? DisplayRepresentation(title: "\(title)") : DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }

    private static func detail(for todo: Todo, in db: TaskDatabase) -> String {
        var parts: [String] = []
        if let project = todo.projectID.flatMap({ db.projects[$0] }) { parts.append(project.title) }
        switch todo.when {
        case .inbox: parts.append("Inbox")
        case .anytime: break
        case .someday: parts.append("Someday")
        case .on(let day): parts.append(day.description)
        }
        return parts.joined(separator: " · ")
    }
}

struct TodoQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [TodoEntity] {
        try await MainActor.run {
            let db = try IntentData.database()
            return identifiers.compactMap { id in db.todos[id].map { TodoEntity($0, in: db) } }
        }
    }

    func entities(matching string: String) async throws -> [TodoEntity] {
        try await MainActor.run {
            let db = try IntentData.database()
            return db.search(string).filter { $0.status == .open }.prefix(20).map { TodoEntity($0, in: db) }
        }
    }

    /// Today's to-dos first, then the rest of Anytime.
    func suggestedEntities() async throws -> [TodoEntity] {
        try await MainActor.run {
            let db = try IntentData.database()
            let today = IntentData.today
            let todos = db.todos(in: .today, today: today) + db.todos(in: .anytime, today: today).filter { !db.classifier(today: today).isIn(.today, $0) }
            return todos.prefix(30).map { TodoEntity($0, in: db) }
        }
    }
}

/// The smart lists, for "Show … in Daybook".
enum ListOption: String, AppEnum {
    case inbox, today, upcoming, anytime, someday, logbook

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    static let caseDisplayRepresentations: [ListOption: DisplayRepresentation] = [
        .inbox: "Inbox", .today: "Today", .upcoming: "Upcoming", .anytime: "Anytime", .someday: "Someday", .logbook: "Logbook",
    ]

    var smartList: SmartList { SmartList(rawValue: rawValue)! }
}

/// Where a new to-do goes when its title doesn't say.
enum AddWhenOption: String, AppEnum {
    case inbox, today, evening, tomorrow, anytime, someday

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "When"
    static let caseDisplayRepresentations: [AddWhenOption: DisplayRepresentation] = [
        .inbox: "Inbox", .today: "Today", .evening: "This Evening", .tomorrow: "Tomorrow", .anytime: "Anytime", .someday: "Someday",
    ]

    var addWhen: DaybookLink.AddWhen { DaybookLink.AddWhen(rawValue: rawValue)! }
}
