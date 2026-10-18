import EventKit
import Foundation
import TaskCore

/// Reads reminders from Apple Reminders for importing. Never changes them.
enum RemindersReader {
    enum ReadError: LocalizedError {
        case denied

        var errorDescription: String? {
            "Daybook doesn't have access to Reminders. Allow it in Settings → Apps → Daybook → Reminders."
        }
    }

    /// All incomplete reminders, from every list.
    static func openReminders() async throws -> [ReminderItem] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw ReadError.denied }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(item))
            }
        }
    }

    private static func item(_ reminder: EKReminder) -> ReminderItem {
        var day: LocalDay?
        var time: TimeOfDay?
        if let due = reminder.dueDateComponents, let year = due.year, let month = due.month, let date = due.day {
            day = LocalDay(year: year, month: month, day: date)
            if let hour = due.hour { time = TimeOfDay(hour: hour, minute: due.minute ?? 0) }
        }
        return ReminderItem(
            title: reminder.title ?? "",
            notes: reminder.notes ?? "",
            listName: reminder.calendar?.title ?? "Reminders",
            url: reminder.url,
            day: day,
            time: time,
            repeatRule: reminder.recurrenceRules?.first.flatMap(rule),
            isCompleted: reminder.isCompleted,
            completedAt: reminder.completionDate,
            createdAt: reminder.creationDate)
    }

    /// The anchor is replaced with the reminder's day by `RemindersImport`.
    private static func rule(_ rule: EKRecurrenceRule) -> RepeatRule? {
        let frequency: RepeatRule.Frequency
        switch rule.frequency {
        case .daily:
            frequency = .daily
        case .weekly:
            frequency = .weekly(Set((rule.daysOfTheWeek ?? []).compactMap { weekday($0.dayOfTheWeek) }))
        case .monthly:
            if let day = rule.daysOfTheMonth?.first?.intValue {
                frequency = .monthly(.day(day))
            } else if let first = rule.daysOfTheWeek?.first, let weekday = weekday(first.dayOfTheWeek) {
                frequency = .monthly(.weekday(ordinal: first.weekNumber == 0 ? 1 : first.weekNumber, weekday))
            } else {
                frequency = .monthly(.day(1))
            }
        case .yearly:
            frequency = .yearly(month: 1, day: 1)  // replaced from the anchor below
        @unknown default:
            return nil
        }
        var end = RepeatRule.End.never
        if let recurrenceEnd = rule.recurrenceEnd {
            if recurrenceEnd.occurrenceCount > 0 {
                end = .count(recurrenceEnd.occurrenceCount)
            } else if let date = recurrenceEnd.endDate {
                end = .until(LocalDay(date))
            }
        }
        return RepeatRule(frequency: frequency, interval: max(rule.interval, 1), end: end, anchor: LocalDay(Date()))
    }

    /// EventKit counts Sunday as 1; Daybook uses ISO weekdays (Monday = 1).
    private static func weekday(_ day: EKWeekday) -> Weekday? {
        Weekday(rawValue: day.rawValue == 1 ? 7 : day.rawValue - 1)
    }
}
