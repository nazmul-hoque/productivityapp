import AppIntents
import Foundation

/// Opens the app's quick add. Used by the Control Center and Lock Screen control; compiled into
/// the app and its extensions so the system can run it in the app.
struct OpenQuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "New To-Do"
    static let description = IntentDescription("Opens Daybook ready to add a to-do.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingLink.leave(URL(string: "daybook://new")!)
        return .result()
    }
}
