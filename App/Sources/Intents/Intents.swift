import AppIntents
import Foundation
import TaskCore

struct AddTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Add To-Do"
    static let description = IntentDescription("Adds a to-do. Dates, times, #tags and /projects in the title work like quick add: “Call Sam tomorrow at 5pm”.")

    @Parameter(title: "To-Do", requestValueDialog: "What's the to-do?")
    var title: String

    @Parameter(title: "Notes")
    var notes: String?

    @Parameter(title: "When", description: "Used when the title doesn't give a date.", default: .inbox)
    var when: AddWhenOption

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to \(\.$when)") {
            \.$notes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TodoEntity> & ProvidesDialog {
        let (todo, db) = try await IntentData.add(title: title, notes: notes, when: when.addWhen)
        return .result(value: TodoEntity(todo, in: db), dialog: "Added “\(todo.title)”.")
    }
}

struct CompleteTodoAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete To-Do"
    static let description = IntentDescription("Marks a to-do as done. A repeating to-do gets its next one.")

    @Parameter(title: "To-Do")
    var todo: TodoEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Complete \(\.$todo)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await IntentData.complete(todo.id)
        return .result(dialog: "Completed “\(todo.title)”.")
    }
}

struct GetTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Today's To-Dos"
    static let description = IntentDescription("The to-dos in Today, including This Evening, in order.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[TodoEntity]> & ProvidesDialog {
        let db = try IntentData.database()
        let sections = db.todaySections(today: IntentData.today)
        let todos = sections.today + sections.evening
        let dialog: IntentDialog = switch todos.count {
        case 0: "Nothing in Today."
        case 1: "One to-do today: \(todos[0].title)."
        default: "\(todos.count) to-dos today. First up: \(todos[0].title)."
        }
        return .result(value: todos.map { TodoEntity($0, in: db) }, dialog: dialog)
    }
}

struct ShowListIntent: AppIntent {
    static let title: LocalizedStringResource = "Show List"
    static let description = IntentDescription("Opens Daybook to a list.")
    static let openAppWhenRun = true

    @Parameter(title: "List", default: .today)
    var list: ListOption

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$list)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        Router.shared.open(.show(list.smartList))
        return .result()
    }
}

/// Phrases Siri knows without setup, and the app's actions in Shortcuts and Spotlight.
struct DaybookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTodoIntent(),
                    phrases: ["Add a to-do in \(.applicationName)", "New \(.applicationName) to-do", "Add to \(.applicationName)"],
                    shortTitle: "Add To-Do", systemImageName: "plus.circle")
        AppShortcut(intent: GetTodayIntent(),
                    phrases: ["What's on my \(.applicationName) today", "What's in \(.applicationName) today"],
                    shortTitle: "Today's To-Dos", systemImageName: "star")
        AppShortcut(intent: ShowListIntent(),
                    phrases: ["Show \(\.$list) in \(.applicationName)", "Open \(\.$list) in \(.applicationName)"],
                    shortTitle: "Show List", systemImageName: "list.bullet")
        AppShortcut(intent: CompleteTodoAppIntent(),
                    phrases: ["Complete a to-do in \(.applicationName)", "Check off a to-do in \(.applicationName)"],
                    shortTitle: "Complete To-Do", systemImageName: "checkmark.circle")
    }
}
