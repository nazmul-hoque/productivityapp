import SwiftUI
import TaskCore

extension SmartList {
    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .today: "Today"
        case .upcoming: "Upcoming"
        case .anytime: "Anytime"
        case .someday: "Someday"
        case .logbook: "Logbook"
        case .trash: "Trash"
        }
    }

    var symbol: String {
        switch self {
        case .inbox: "tray.fill"
        case .today: "star.fill"
        case .upcoming: "calendar"
        case .anytime: "square.stack.3d.up.fill"
        case .someday: "archivebox.fill"
        case .logbook: "checkmark.seal.fill"
        case .trash: "trash.fill"
        }
    }

    var tint: Color {
        switch self {
        case .inbox: .blue
        case .today: .yellow
        case .upcoming: .red
        case .anytime: .teal
        case .someday: .brown
        case .logbook: .green
        case .trash: .gray
        }
    }
}

enum Theme {
    static let evening = Color.indigo
    static let deadline = Color.red
}

/// Human-friendly day labels relative to today.
enum DayLabel {
    static func short(_ day: LocalDay, today: LocalDay) -> String {
        let delta = today.days(until: day)
        switch delta {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return format(day, "EEEE")
        default: return format(day, day.year == today.year ? "MMMd" : "yMMMd")
        }
    }

    /// e.g. "Mon, Oct 19", used for Upcoming headers.
    static func long(_ day: LocalDay) -> String {
        format(day, "EEEMMMd")
    }

    private static func format(_ day: LocalDay, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: day.date())
    }
}
