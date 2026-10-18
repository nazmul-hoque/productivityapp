/// How a to-do repeats.
public struct RepeatRule: Hashable, Codable, Sendable {
    public enum Frequency: Hashable, Codable, Sendable {
        case daily
        /// Repeats on these weekdays; an empty set means the anchor's weekday.
        case weekly(Set<Weekday>)
        case monthly(MonthlyPattern)
        /// Feb 29 falls back to Feb 28 in non-leap years.
        case yearly(month: Int, day: Int)
    }

    public enum MonthlyPattern: Hashable, Codable, Sendable {
        /// Day of month 1…31 (clamped to the month length), or -1 for the last day.
        case day(Int)
        /// e.g. 2nd Tuesday (`ordinal` 1…5) or last Friday (`ordinal` -1). Months without
        /// a 5th occurrence are skipped.
        case weekday(ordinal: Int, Weekday)
    }

    public enum Mode: String, Codable, Sendable {
        /// On a fixed calendar schedule, regardless of when the previous one was done.
        case fixed
        /// `interval` units after the previous one was completed.
        case afterCompletion
    }

    public enum End: Hashable, Codable, Sendable {
        case never
        case until(LocalDay)
        /// Stops after this many occurrences.
        case count(Int)
    }

    public var frequency: Frequency
    /// Every `interval` days/weeks/months/years. At least 1.
    public var interval: Int
    public var mode: Mode
    public var end: End
    /// First day of the series; fixed schedules are computed from it.
    public var anchor: LocalDay
    /// Each occurrence gets a deadline this many days after its start day.
    public var deadlineOffset: Int?
    /// Reminder time copied onto each occurrence.
    public var reminder: TimeOfDay?

    public init(
        frequency: Frequency,
        interval: Int = 1,
        mode: Mode = .fixed,
        end: End = .never,
        anchor: LocalDay,
        deadlineOffset: Int? = nil,
        reminder: TimeOfDay? = nil
    ) {
        precondition(interval >= 1, "interval must be at least 1")
        self.frequency = frequency
        self.interval = interval
        self.mode = mode
        self.end = end
        self.anchor = anchor
        self.deadlineOffset = deadlineOffset
        self.reminder = reminder
    }
}
