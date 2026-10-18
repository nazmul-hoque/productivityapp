import Foundation

/// A `daybook://` link left for the app by an extension or an intent, to follow when it opens.
/// Kept in the App Group's defaults, since the control and the app are different processes.
enum PendingLink {
    /// Posted in the app's process when a link is left while the app is already running.
    static let notification = Notification.Name("com.nazmulhoque.daybook.pending-link")
    private static let key = "pendingLink"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: SharedStore.appGroup)
    }

    static func leave(_ url: URL) {
        defaults?.set(url.absoluteString, forKey: key)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    /// The link left most recently, if any, removing it.
    static func take() -> URL? {
        guard let string = defaults?.string(forKey: key) else { return nil }
        defaults?.removeObject(forKey: key)
        return URL(string: string)
    }
}
