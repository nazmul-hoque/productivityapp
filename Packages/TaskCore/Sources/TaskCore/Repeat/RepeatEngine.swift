/// One scheduled instance of a repeating series.
public struct Occurrence: Hashable, Sendable {
    public var day: LocalDay
    /// 1-based position in the series.
    public var index: Int

    public init(day: LocalDay, index: Int) {
        self.day = day
        self.index = index
    }
}

public enum RepeatEngine {
    /// Guards against rules that can never produce a day (or loop for ever).
    static let maxPeriods = 20_000

    /// Fixed-schedule occurrences within `range`, honouring the rule's end condition.
    public static func occurrences(of rule: RepeatRule, in range: ClosedRange<LocalDay>, limit: Int = 1_000) -> [Occurrence] {
        var result: [Occurrence] = []
        forEachOccurrence(of: rule) { occurrence in
            if occurrence.day > range.upperBound || result.count >= limit { return false }
            if occurrence.day >= range.lowerBound { result.append(occurrence) }
            return true
        }
        return result
    }

    /// The first fixed-schedule occurrence strictly after `day`.
    public static func occurrence(of rule: RepeatRule, after day: LocalDay) -> Occurrence? {
        var found: Occurrence?
        forEachOccurrence(of: rule) { occurrence in
            if occurrence.day > day {
                found = occurrence
                return false
            }
            return true
        }
        return found
    }

    /// The occurrence that should replace `current` once it is completed (or canceled).
    ///
    /// - Fixed rules continue from the scheduled day, so completing early does not skip
    ///   the next one; occurrences already in the past are skipped.
    /// - After-completion rules count from the day it was completed.
    ///
    /// Returns `nil` when the series has ended.
    public static func next(after current: Occurrence, of rule: RepeatRule, completedOn: LocalDay, today: LocalDay) -> Occurrence? {
        switch rule.mode {
        case .fixed:
            return occurrence(of: rule, after: max(current.day, today.adding(days: -1)))
        case .afterCompletion:
            let day = advance(completedOn, by: rule.frequency, interval: rule.interval)
            let next = Occurrence(day: day, index: current.index + 1)
            return isWithinEnd(next, rule) ? next : nil
        }
    }

    /// The rule after the user moves the whole series ("update rule") to start on `day`.
    public static func rule(_ rule: RepeatRule, rescheduledTo day: LocalDay) -> RepeatRule {
        var updated = rule
        updated.anchor = day
        guard rule.mode == .fixed else { return updated }
        switch rule.frequency {
        case .daily:
            break
        case .weekly(let weekdays):
            if weekdays.count <= 1 { updated.frequency = .weekly([day.weekday]) }
        case .monthly(.day):
            updated.frequency = .monthly(.day(day.day))
        case .monthly(.weekday(let ordinal, _)):
            let newOrdinal = ordinal == -1 ? -1 : min((day.day - 1) / 7 + 1, 5)
            updated.frequency = .monthly(.weekday(ordinal: newOrdinal, day.weekday))
        case .yearly:
            updated.frequency = .yearly(month: day.month, day: day.day)
        }
        return updated
    }

    // MARK: - Generation

    /// Walks fixed-schedule occurrences in ascending order until `body` returns false
    /// or the series ends.
    static func forEachOccurrence(of rule: RepeatRule, _ body: (Occurrence) -> Bool) {
        var index = 0
        for period in 0..<maxPeriods {
            for day in days(inPeriod: period, of: rule) where day >= rule.anchor {
                index += 1
                let occurrence = Occurrence(day: day, index: index)
                guard isWithinEnd(occurrence, rule), body(occurrence) else { return }
            }
        }
    }

    /// Candidate days for the `period`-th period (day, week, month or year) after the anchor.
    static func days(inPeriod period: Int, of rule: RepeatRule) -> [LocalDay] {
        let step = period * rule.interval
        let anchor = rule.anchor
        switch rule.frequency {
        case .daily:
            return [anchor.adding(days: step)]
        case .weekly(let weekdays):
            let weekStart = anchor.startOfWeek.adding(days: 7 * step)
            let selected = weekdays.isEmpty ? [anchor.weekday] : weekdays.sorted()
            return selected.map { weekStart.adding(days: $0.rawValue - 1) }
        case .monthly(let pattern):
            let month = LocalDay(year: anchor.year, month: anchor.month, day: 1).adding(months: step)
            return monthlyDay(pattern, in: month).map { [$0] } ?? []
        case .yearly(let m, let d):
            return [LocalDay(year: anchor.year + step, month: m, day: d)]
        }
    }

    static func monthlyDay(_ pattern: RepeatRule.MonthlyPattern, in month: LocalDay) -> LocalDay? {
        switch pattern {
        case .day(let n):
            let day = n == -1 ? month.daysInMonth : min(max(n, 1), month.daysInMonth)
            return LocalDay(year: month.year, month: month.month, day: day)
        case .weekday(let ordinal, let weekday):
            if ordinal == -1 {
                let last = LocalDay(year: month.year, month: month.month, day: month.daysInMonth)
                return last.adding(days: -((last.weekday.rawValue - weekday.rawValue + 7) % 7))
            }
            let first = month.next(weekday)
            let day = first.adding(days: 7 * (ordinal - 1))
            return day.month == month.month ? day : nil
        }
    }

    static func advance(_ day: LocalDay, by frequency: RepeatRule.Frequency, interval: Int) -> LocalDay {
        switch frequency {
        case .daily: return day.adding(days: interval)
        case .weekly: return day.adding(days: 7 * interval)
        case .monthly: return day.adding(months: interval)
        case .yearly: return day.adding(years: interval)
        }
    }

    static func isWithinEnd(_ occurrence: Occurrence, _ rule: RepeatRule) -> Bool {
        switch rule.end {
        case .never: return true
        case .until(let last): return occurrence.day <= last
        case .count(let n): return occurrence.index <= n
        }
    }
}
