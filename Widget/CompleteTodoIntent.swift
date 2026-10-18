import AppIntents
import Foundation
import TaskCore
import TaskStore
import UserNotifications

/// Completes a to-do from the widget. Runs in the widget's process and writes the shared
/// database directly; the app picks the change up when it next comes to the foreground.
struct CompleteTodoIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete To-Do"
    static let isDiscoverable = false

    @Parameter(title: "To-Do ID")
    var todoID: String

    init() {}

    init(todoID: UUID) {
        self.todoID = todoID.uuidString
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: todoID), let url = SharedStore.databaseURL else { return .result() }
        // Same rules as in the app: a repeating to-do gets its next instance.
        try SQLiteStore(url: url).update { _ = $0.complete(id) }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [todoID])
        return .result()
    }
}
