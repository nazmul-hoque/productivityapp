import Testing
@testable import TaskCore

struct RepeatEngineTests {
    func days(_ rule: RepeatRule, _ from: String, _ to: String) -> [String] {
        RepeatEngine.occurrences(of: rule, in: day(from)...day(to)).map(\.day.description)
    }

    @Test func dailyWithInterval() {
        let rule = RepeatRule(frequency: .daily, interval: 3, anchor: day("2026-10-14"))
        #expect(days(rule, "2026-10-14", "2026-10-24") == ["2026-10-14", "2026-10-17", "2026-10-20", "2026-10-23"])
    }

    @Test func weeklyOnSeveralDays() {
        let rule = RepeatRule(frequency: .weekly([.monday, .wednesday, .friday]), anchor: day("2026-10-14"))
        // Starts at the Wednesday anchor, not the Monday before it.
        #expect(days(rule, "2026-10-01", "2026-10-21") == ["2026-10-14", "2026-10-16", "2026-10-19", "2026-10-21"])
    }

    @Test func everyOtherWeek() {
        let rule = RepeatRule(frequency: .weekly([]), interval: 2, anchor: day("2026-10-14"))
        #expect(days(rule, "2026-10-14", "2026-11-30") == ["2026-10-14", "2026-10-28", "2026-11-11", "2026-11-25"])
    }

    @Test func monthlyDayClampsAndLastDay() {
        let rule31 = RepeatRule(frequency: .monthly(.day(31)), anchor: day("2026-01-31"))
        #expect(days(rule31, "2026-01-01", "2026-04-30") == ["2026-01-31", "2026-02-28", "2026-03-31", "2026-04-30"])
        let last = RepeatRule(frequency: .monthly(.day(-1)), anchor: day("2028-01-01"))
        #expect(days(last, "2028-01-01", "2028-03-31") == ["2028-01-31", "2028-02-29", "2028-03-31"])
    }

    @Test func monthlyNthWeekday() {
        let second = RepeatRule(frequency: .monthly(.weekday(ordinal: 2, .tuesday)), anchor: day("2026-10-01"))
        #expect(days(second, "2026-10-01", "2026-12-31") == ["2026-10-13", "2026-11-10", "2026-12-08"])
        let lastFriday = RepeatRule(frequency: .monthly(.weekday(ordinal: -1, .friday)), anchor: day("2026-10-01"))
        #expect(days(lastFriday, "2026-10-01", "2026-12-31") == ["2026-10-30", "2026-11-27", "2026-12-25"])
        // Months without a 5th Thursday are skipped.
        let fifth = RepeatRule(frequency: .monthly(.weekday(ordinal: 5, .thursday)), anchor: day("2026-10-01"))
        #expect(days(fifth, "2026-10-01", "2027-01-31") == ["2026-10-29", "2026-12-31"])
    }

    @Test func yearlyLeapDay() {
        let rule = RepeatRule(frequency: .yearly(month: 2, day: 29), anchor: day("2028-02-29"))
        #expect(days(rule, "2028-01-01", "2030-12-31") == ["2028-02-29", "2029-02-28", "2030-02-28"])
    }

    @Test func endConditions() {
        let counted = RepeatRule(frequency: .daily, end: .count(3), anchor: day("2026-10-14"))
        #expect(days(counted, "2026-10-01", "2026-12-31") == ["2026-10-14", "2026-10-15", "2026-10-16"])
        let until = RepeatRule(frequency: .weekly([]), end: .until(day("2026-10-28")), anchor: day("2026-10-14"))
        #expect(days(until, "2026-10-01", "2026-12-31") == ["2026-10-14", "2026-10-21", "2026-10-28"])
    }

    @Test func completingEarlyDoesNotSkipTheNextOne() {
        // Weekly on Friday; Friday the 16th's instance done on Wednesday the 14th.
        let rule = RepeatRule(frequency: .weekly([.friday]), anchor: day("2026-10-02"))
        let current = Occurrence(day: day("2026-10-16"), index: 3)
        let next = RepeatEngine.next(after: current, of: rule, completedOn: day("2026-10-14"), today: day("2026-10-14"))
        #expect(next == Occurrence(day: day("2026-10-23"), index: 4))
    }

    @Test func completingLateSkipsMissedOccurrences() {
        let rule = RepeatRule(frequency: .weekly([.monday]), anchor: day("2026-09-07"))
        let current = Occurrence(day: day("2026-09-21"), index: 3)
        let next = RepeatEngine.next(after: current, of: rule, completedOn: day("2026-10-14"), today: day("2026-10-14"))
        #expect(next?.day == day("2026-10-19"))
    }

    @Test func afterCompletionCountsFromCompletionDay() {
        let rule = RepeatRule(frequency: .weekly([]), interval: 2, mode: .afterCompletion, anchor: day("2026-10-01"))
        let next = RepeatEngine.next(after: Occurrence(day: day("2026-10-01"), index: 1), of: rule,
                                     completedOn: day("2026-10-05"), today: day("2026-10-05"))
        #expect(next == Occurrence(day: day("2026-10-19"), index: 2))
    }

    @Test func seriesEnds() {
        let rule = RepeatRule(frequency: .daily, mode: .afterCompletion, end: .count(2), anchor: day("2026-10-01"))
        #expect(RepeatEngine.next(after: Occurrence(day: day("2026-10-02"), index: 2), of: rule,
                                  completedOn: day("2026-10-02"), today: day("2026-10-02")) == nil)
        let fixed = RepeatRule(frequency: .daily, end: .until(day("2026-10-03")), anchor: day("2026-10-01"))
        #expect(RepeatEngine.next(after: Occurrence(day: day("2026-10-03"), index: 3), of: fixed,
                                  completedOn: day("2026-10-03"), today: day("2026-10-03")) == nil)
    }

    @Test func reschedulingTheSeries() {
        let weekly = RepeatRule(frequency: .weekly([.monday]), anchor: day("2026-10-05"))
        let moved = RepeatEngine.rule(weekly, rescheduledTo: day("2026-10-15"))
        #expect(moved.frequency == .weekly([.thursday]))
        #expect(moved.anchor == day("2026-10-15"))

        let monthly = RepeatRule(frequency: .monthly(.day(5)), anchor: day("2026-10-05"))
        #expect(RepeatEngine.rule(monthly, rescheduledTo: day("2026-10-20")).frequency == .monthly(.day(20)))

        let nth = RepeatRule(frequency: .monthly(.weekday(ordinal: 1, .monday)), anchor: day("2026-10-05"))
        #expect(RepeatEngine.rule(nth, rescheduledTo: day("2026-10-15")).frequency == .monthly(.weekday(ordinal: 3, .thursday)))

        let multi = RepeatRule(frequency: .weekly([.monday, .friday]), anchor: day("2026-10-05"))
        #expect(RepeatEngine.rule(multi, rescheduledTo: day("2026-10-15")).frequency == .weekly([.monday, .friday]))
    }
}
