import Foundation

/// Where the database lives in the App Group container. Compiled into the app and the widget
/// extension so both open the same file.
enum SharedStore {
    static let appGroup = "group.com.nazmulhoque.productivityapp"

    /// `nil` when the App Group container is unavailable (a build without the entitlement).
    static var databaseURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Database", isDirectory: true)
            .appendingPathComponent("tasks.sqlite")
    }

    /// Opened by the widget to show Today.
    static let todayURL = URL(string: "productivity://today")!
}
