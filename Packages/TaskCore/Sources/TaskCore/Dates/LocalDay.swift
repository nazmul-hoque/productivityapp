import Foundation

/// A calendar day with no time or time zone attached (e.g. a start date or deadline).
///
/// Arithmetic uses a days-since-epoch representation of the proleptic Gregorian
/// calendar, so it is deterministic and independent of the device's calendar settings.
public struct LocalDay: Hashable, Comparable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Creates a day, clamping `day` to the length of the month.
    public init(year: Int, month: Int, day: Int) {
        precondition((1...12).contains(month), "month out of range: \(month)")
        self.year = year
        self.month = month
        self.day = min(max(day, 1), LocalDay.daysIn(month: month, year: year))
    }

    /// Creates a day from the number of days since 1970-01-01.
    public init(dayNumber: Int) {
        let (y, m, d) = LocalDay.civil(fromDays: dayNumber)
        self.init(year: y, month: m, day: d)
    }

    /// The day containing `date` in `timeZone`.
    public init(_ date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Parses `yyyy-mm-dd`.
    public init?(iso string: String) {
        let parts = string.split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), d >= 1, d <= LocalDay.daysIn(month: m, year: y)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// Days since 1970-01-01.
    public var dayNumber: Int { LocalDay.days(fromCivil: year, month, day) }

    public var weekday: Weekday {
        // 1970-01-01 was a Thursday.
        let index = ((dayNumber % 7) + 7 + 3) % 7  // 0 = Monday
        return Weekday(rawValue: index + 1)!
    }

    public var daysInMonth: Int { LocalDay.daysIn(month: month, year: year) }

    public func adding(days: Int) -> LocalDay { LocalDay(dayNumber: dayNumber + days) }

    /// Adds calendar months, clamping the day (Jan 31 + 1 month = Feb 28/29).
    public func adding(months: Int) -> LocalDay {
        let total = (year * 12 + (month - 1)) + months
        let y = Int((Double(total) / 12).rounded(.down))
        return LocalDay(year: y, month: total - y * 12 + 1, day: day)
    }

    public func adding(years: Int) -> LocalDay { LocalDay(year: year + years, month: month, day: day) }

    public func days(until other: LocalDay) -> Int { other.dayNumber - dayNumber }

    /// The Monday on or before this day.
    public var startOfWeek: LocalDay { adding(days: -(weekday.rawValue - 1)) }

    /// The given weekday on or after this day.
    public func next(_ weekday: Weekday, includingToday: Bool = true) -> LocalDay {
        var delta = (weekday.rawValue - self.weekday.rawValue + 7) % 7
        if delta == 0 && !includingToday { delta = 7 }
        return adding(days: delta)
    }

    /// The moment this day starts (or `time` on this day) in `timeZone`.
    public func date(at time: TimeOfDay = .midnight, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: time.hour, minute: time.minute)
        return calendar.date(from: components)!
    }

    public static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    public static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return isLeap(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    // Howard Hinnant's civil-calendar algorithms.
    static func days(fromCivil year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromDays days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }
}

extension LocalDay: CustomStringConvertible {
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

extension LocalDay: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let day = LocalDay(iso: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid day: \(string)")
        }
        self = day
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// ISO weekday: Monday = 1 … Sunday = 7.
public enum Weekday: Int, CaseIterable, Codable, Sendable, Comparable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A wall-clock time, used for reminders.
public struct TimeOfDay: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int = 0) {
        precondition((0...23).contains(hour) && (0...59).contains(minute), "invalid time \(hour):\(minute)")
        self.hour = hour
        self.minute = minute
    }

    public static let midnight = TimeOfDay(hour: 0)
    public static let noon = TimeOfDay(hour: 12)

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    public var description: String { String(format: "%02d:%02d", hour, minute) }
}
