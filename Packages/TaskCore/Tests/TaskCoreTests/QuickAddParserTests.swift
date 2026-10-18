import Testing
@testable import TaskCore

struct QuickAddParserTests {
    // Wednesday.
    let parser = QuickAddParser(today: day("2026-10-14"))

    @Test func plainTitle() {
        #expect(parser.parse("Buy 10 eggs") == QuickAddResult(title: "Buy 10 eggs"))
        #expect(parser.parse("  Read   a book ") == QuickAddResult(title: "Read a book"))
    }

    @Test func fullExample() {
        let result = parser.parse("Call Sarah tomorrow at 10am #phone /Work !friday")
        #expect(result == QuickAddResult(title: "Call Sarah", when: .on(day("2026-10-15")), reminder: TimeOfDay(hour: 10),
                                         deadline: day("2026-10-16"), tags: ["phone"], project: "Work"))
    }

    @Test(arguments: [
        ("today", "2026-10-14"), ("tod", "2026-10-14"), ("tomorrow", "2026-10-15"), ("tmrw", "2026-10-15"),
        ("wed", "2026-10-14"), ("friday", "2026-10-16"), ("mon", "2026-10-19"), ("this sat", "2026-10-17"),
        ("next friday", "2026-10-23"), ("next week", "2026-10-19"), ("next month", "2026-11-01"),
        ("weekend", "2026-10-17"), ("next weekend", "2026-10-24"),
        ("in 3 days", "2026-10-17"), ("in a week", "2026-10-21"), ("in 2 months", "2026-12-14"),
        ("oct 20", "2026-10-20"), ("20 oct", "2026-10-20"), ("October 20th", "2026-10-20"),
        ("jan 5", "2027-01-05"), ("oct 1", "2027-10-01"), ("mar 3 2028", "2028-03-03"),
        ("2026-12-01", "2026-12-01"), ("on friday", "2026-10-16"),
    ])
    func datePhrases(phrase: String, expected: String) {
        let result = parser.parse("Water plants \(phrase)")
        #expect(result.title == "Water plants")
        #expect(result.when == .on(day(expected)))
    }

    @Test func buckets() {
        #expect(parser.parse("Learn piano someday") == QuickAddResult(title: "Learn piano", when: .someday))
        #expect(parser.parse("Tidy desk anytime") == QuickAddResult(title: "Tidy desk", when: .anytime))
    }

    @Test func evening() {
        #expect(parser.parse("Watch film tonight") == QuickAddResult(title: "Watch film", when: .on(day("2026-10-14")), isEvening: true))
        #expect(parser.parse("Watch film this evening").isEvening)
        // A reminder at 6pm or later today lands in This Evening.
        #expect(parser.parse("Call mom at 7pm") == QuickAddResult(title: "Call mom", when: .on(day("2026-10-14")),
                                                                    isEvening: true, reminder: TimeOfDay(hour: 19)))
    }

    @Test(arguments: [
        ("at 10", 10, 0), ("at 3", 15, 0), ("at 10:30", 10, 30), ("10am", 10, 0), ("10 am", 10, 0),
        ("9:30pm", 21, 30), ("at 12am", 0, 0), ("12pm", 12, 0), ("21:15", 21, 15), ("noon", 12, 0), ("at 5p", 17, 0),
    ])
    func times(phrase: String, hour: Int, minute: Int) {
        let result = parser.parse("Standup tomorrow \(phrase)")
        #expect(result.title == "Standup")
        #expect(result.reminder == TimeOfDay(hour: hour, minute: minute))
        #expect(result.when == .on(day("2026-10-15")))
    }

    @Test func notTimes() {
        #expect(parser.parse("Buy 3 apples").reminder == nil)
        #expect(parser.parse("Room 101").title == "Room 101")
        #expect(parser.parse("Bake at 400 degrees").title == "Bake at 400 degrees")
    }

    @Test func deadlines() {
        #expect(parser.parse("File taxes by friday") == QuickAddResult(title: "File taxes", deadline: day("2026-10-16")))
        #expect(parser.parse("Report due next week") == QuickAddResult(title: "Report", deadline: day("2026-10-19")))
        #expect(parser.parse("Essay !oct 30") == QuickAddResult(title: "Essay", deadline: day("2026-10-30")))
        #expect(parser.parse("Pay rent friday !monday") == QuickAddResult(title: "Pay rent", when: .on(day("2026-10-16")),
                                                                            deadline: day("2026-10-19")))
        // "!" with no date stays in the title.
        #expect(parser.parse("Wow !amazing").title == "Wow !amazing")
    }

    @Test func tagsAndProjects() {
        let result = parser.parse("Buy paint #errands #\"low energy\" /\"Home Reno\"")
        #expect(result.title == "Buy paint")
        #expect(result.tags == ["errands", "low energy"])
        #expect(result.project == "Home Reno")
        #expect(parser.parse("Pick and/or choose").title == "Pick and/or choose")
    }

    @Test func onlyFirstDateIsUsed() {
        let result = parser.parse("Plan friday party tomorrow")
        #expect(result.when == .on(day("2026-10-16")))
        #expect(result.title == "Plan party tomorrow")
    }

    @Test func emptyTitleKeepsOriginalText() {
        #expect(parser.parse("tomorrow") == QuickAddResult(title: "tomorrow"))
        #expect(parser.parse("") == QuickAddResult(title: ""))
    }

    @Test func trailingPunctuation() {
        #expect(parser.parse("Email Bob tomorrow, re: invoice") == QuickAddResult(title: "Email Bob re: invoice",
                                                                                    when: .on(day("2026-10-15"))))
    }
}
