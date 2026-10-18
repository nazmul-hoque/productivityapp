import Foundation
import TaskCore
import UserNotifications

/// Schedules local notifications for to-do reminders, so they fire offline.
@MainActor
final class ReminderScheduler {
    /// iOS keeps at most 64 pending notifications per app.
    private let limit = 60

    /// Replaces all pending reminders with the next ones due. Asks for permission the first
    /// time there is a reminder to schedule, rather than at launch, so the prompt makes sense.
    func sync(with db: TaskDatabase) async {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let due: [(Todo, Date)] = db.todos.values.compactMap { todo in
            guard todo.status == .open, !todo.isDeleted, let time = todo.reminder, case .on(let day) = todo.when else { return nil }
            let fire = day.date(at: time)
            return fire > now ? (todo, fire) : nil
        }
        .sorted { $0.1 < $1.1 }

        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined && !due.isEmpty {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else { return }

        center.removeAllPendingNotificationRequests()
        for (todo, fire) in due.prefix(limit) {
            let content = UNMutableNotificationContent()
            content.title = todo.title
            if let project = todo.projectID.flatMap({ db.projects[$0] }) {
                content.subtitle = project.title
            }
            if !todo.notes.isEmpty { content.body = todo.notes }
            content.sound = .default
            content.categoryIdentifier = ReminderAction.category
            content.userInfo = [ReminderAction.todoKey: todo.id.uuidString]
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(identifier: todo.id.uuidString, content: content, trigger: trigger)
            try? await center.add(request)
        }
    }
}
