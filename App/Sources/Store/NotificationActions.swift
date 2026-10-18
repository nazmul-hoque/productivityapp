import Foundation
import TaskCore
import UIKit
import UserNotifications

/// Buttons on a reminder notification. iOS runs them in the background, without opening the app.
enum ReminderAction: String, CaseIterable {
    case snoozeHour = "snooze-hour"
    case snoozeTomorrow = "snooze-tomorrow"
    case complete

    static let category = "reminder"
    /// `userInfo` key holding the to-do's id.
    static let todoKey = "todoID"

    static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: category, actions: [
            UNNotificationAction(identifier: snoozeHour.rawValue, title: "Snooze 1 Hour", icon: UNNotificationActionIcon(systemImageName: "clock")),
            UNNotificationAction(identifier: snoozeTomorrow.rawValue, title: "Tomorrow", icon: UNNotificationActionIcon(systemImageName: "sunrise")),
            UNNotificationAction(identifier: complete.rawValue, title: "Complete", icon: UNNotificationActionIcon(systemImageName: "checkmark.circle")),
        ], intentIdentifiers: [])
    }
}

/// Owns the store so notification actions can reach it, including when iOS launches the
/// app in the background just to handle one.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let store: AppStore
    let sync: SyncController

    override init() {
        let store = AppStore()
        self.store = store
        sync = SyncController(store: store)
        super.init()
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Must be set before launch finishes, or an action that launched the app is missed.
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([ReminderAction.notificationCategory])
        return true
    }

    /// Show reminders while the app is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let action = ReminderAction(rawValue: response.actionIdentifier),
              let id = (response.notification.request.content.userInfo[ReminderAction.todoKey] as? String).flatMap(UUID.init)
        else { return }
        await store.handle(action, for: id)
    }
}
