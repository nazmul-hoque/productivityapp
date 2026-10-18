import SwiftUI
import TaskCore

/// The repeat choices offered in the editors.
enum RepeatKind: String, CaseIterable, Identifiable {
    case never, daily, weekly, monthly, yearly
    var id: Self { self }

    var unit: String {
        switch self {
        case .never, .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        case .yearly: "year"
        }
    }

    init(_ frequency: RepeatRule.Frequency?) {
        switch frequency {
        case nil: self = .never
        case .daily: self = .daily
        case .weekly: self = .weekly
        case .monthly: self = .monthly
        case .yearly: self = .yearly
        }
    }

    /// A simple frequency of this kind for a series starting on `anchor`.
    func frequency(anchor: LocalDay) -> RepeatRule.Frequency {
        switch self {
        case .never, .daily: .daily
        case .weekly: .weekly([])
        case .monthly: .monthly(.day(anchor.day))
        case .yearly: .yearly(month: anchor.month, day: anchor.day)
        }
    }
}

/// Repeat, interval and schedule pickers, shared by the to-do and project editors.
struct RepeatFields: View {
    @Binding var kind: RepeatKind
    @Binding var interval: Int
    @Binding var mode: RepeatRule.Mode

    var body: some View {
        Picker("Repeat", selection: $kind) {
            ForEach(RepeatKind.allCases) { Text($0.rawValue.capitalized).tag($0) }
        }
        if kind != .never {
            Stepper(interval == 1 ? "Every \(kind.unit)" : "Every \(interval) \(kind.unit)s",
                    value: $interval, in: 1...99)
            Picker("Schedule", selection: $mode) {
                Text("Fixed schedule").tag(RepeatRule.Mode.fixed)
                Text("After completion").tag(RepeatRule.Mode.afterCompletion)
            }
        }
    }
}

extension RepeatRule {
    /// e.g. "Every month", "Every 2 weeks after completion".
    var summary: String {
        let kind = RepeatKind(frequency)
        let every = interval == 1 ? "Every \(kind.unit)" : "Every \(interval) \(kind.unit)s"
        return mode == .afterCompletion ? every + " after completion" : every
    }
}
