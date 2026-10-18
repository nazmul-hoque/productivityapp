import Foundation
import Testing
@testable import TaskCore

struct TaskDatabaseTests {
    let utc = TimeZone(identifier: "UTC")!
    let today = day("2026-10-14")
    var now: Date { today.date(at: TimeOfDay(hour: 9), timeZone: utc) }

    @Test func todayOrderingIsIndependentOfListOrder() {
        var db = TaskDatabase()
        let a = db.add(Todo(title: "a", when: .on(today)), today: today)
        let b = db.add(Todo(title: "b", when: .on(today)), today: today)
        let c = db.add(Todo(title: "c", when: .anytime), today: today)
        #expect(db.todos(in: .today, today: today).map(\.title) == ["a", "b"])

        db.schedule(c.id, .on(today), today: today)
        #expect(db.todos(in: .today, today: today).map(\.title) == ["a", "b", "c"])

        db.reorder(c.id, after: nil, before: a.id, inToday: true)
        #expect(db.todos(in: .today, today: today).map(\.title) == ["c", "a", "b"])
        db.reorder(a.id, after: b.id, before: nil, inToday: true)
        #expect(db.todos(in: .today, today: today).map(\.title) == ["c", "b", "a"])
        // Anytime order is untouched.
        #expect(db.todos(in: .anytime, today: today).map(\.title) == ["a", "b", "c"])
    }

    @Test func todaySections() {
        var db = TaskDatabase()
        db.add(Todo(title: "day", when: .on(today)), today: today)
        db.add(Todo(title: "night", when: .on(today), isEvening: true), today: today)
        let sections = db.todaySections(today: today)
        #expect(sections.today.map(\.title) == ["day"])
        #expect(sections.evening.map(\.title) == ["night"])
    }

    @Test func completingARepeatingTodoCreatesTheNextOne() {
        var db = TaskDatabase()
        let rule = RepeatRule(frequency: .weekly([.wednesday]), anchor: today, deadlineOffset: 2, reminder: TimeOfDay(hour: 8))
        let todo = db.add(Todo(title: "Bins", when: .on(today), reminder: TimeOfDay(hour: 8),
                               repetition: Repetition(rule: rule, occurrence: today),
                               checklist: [ChecklistItem(title: "Recycling", isDone: true)]), today: today)

        let next = db.complete(todo.id, now: now, timeZone: utc)
        #expect(db.todos[todo.id]?.status == .completed)
        #expect(next?.when == .on(day("2026-10-21")))
        #expect(next?.deadline == day("2026-10-23"))
        #expect(next?.checklist.first?.isDone == false)
        #expect(next?.repetition?.index == 2)
        #expect(db.todos(in: .logbook, today: today).map(\.id) == [todo.id])
        #expect(db.todos(in: .upcoming, today: today).map(\.id) == [next!.id])

        // Completing the old instance again does nothing.
        #expect(db.complete(todo.id, now: now, timeZone: utc) == nil)
    }

    @Test func upcomingIncludesRepeatPreviews() {
        var db = TaskDatabase()
        let rule = RepeatRule(frequency: .weekly([.monday]), anchor: day("2026-10-19"))
        db.add(Todo(title: "Gym", when: .on(day("2026-10-19")), repetition: Repetition(rule: rule, occurrence: day("2026-10-19"))), today: today)
        db.add(Todo(title: "Dentist", when: .on(day("2026-10-20"))), today: today)
        let groups = db.upcoming(today: today, horizon: 14)
        #expect(groups.map(\.day) == [day("2026-10-19"), day("2026-10-20"), day("2026-10-26")])
        #expect(groups.map { $0.todos.map(\.title) } == [["Gym"], ["Dentist"], ["Gym"]])
    }

    @Test func rescheduleJustThisOneVsSeries() {
        var db = TaskDatabase()
        let rule = RepeatRule(frequency: .weekly([.monday]), anchor: day("2026-10-12"))
        let todo = db.add(Todo(title: "Report", when: .on(today), repetition: Repetition(rule: rule, occurrence: day("2026-10-12"))), today: today)

        db.rescheduleOccurrence(todo.id, to: day("2026-10-16"), today: today)
        var next = db.complete(todo.id, now: now, timeZone: utc)
        #expect(next?.when == .on(day("2026-10-19")))  // still Mondays

        db.rescheduleSeries(next!.id, to: day("2026-10-22"), today: today)
        next = db.complete(next!.id, now: now, timeZone: utc)
        #expect(next?.when == .on(day("2026-10-29")))  // now Thursdays
    }

    @Test func movingBetweenInboxProjectsAndAreas() {
        var db = TaskDatabase()
        let project = db.addProject(Project(title: "Trip"))
        let heading = db.addHeading("Packing", toProject: project.id)
        let todo = db.add(Todo(title: "Passport"), today: today)
        #expect(db.todos(in: .inbox, today: today).count == 1)

        db.move(todo.id, toProject: project.id, heading: heading.id)
        #expect(db.todos[todo.id]?.when == .anytime)
        #expect(db.sections(ofProject: project.id).map { $0.todos.map(\.title) } == [[], ["Passport"]])

        db.move(todo.id, toProject: nil)
        #expect(db.todos[todo.id]?.when == .inbox)
        #expect(db.todos[todo.id]?.headingID == nil)
    }

    @Test func convertToProject() {
        var db = TaskDatabase()
        let todo = db.add(Todo(title: "Plan party", notes: "Saturday", when: .inbox, deadline: day("2026-10-31"),
                               checklist: [ChecklistItem(title: "Invite"), ChecklistItem(title: "Cake", isDone: true)]), today: today)
        let project = db.convertToProject(todo.id, today: today)!
        #expect(db.todos[todo.id] == nil)
        #expect(project.title == "Plan party" && project.notes == "Saturday" && project.when == .anytime)
        #expect(project.deadline == day("2026-10-31"))
        #expect(db.sections(ofProject: project.id).first?.todos.map(\.title) == ["Invite"])
        #expect(db.progress(ofProject: project.id) == 0.5)
    }

    @Test func completingAProjectClosesItsTodos() {
        var db = TaskDatabase()
        let project = db.addProject(Project(title: "P"))
        let todo = db.add(Todo(title: "t", projectID: project.id, when: .anytime), today: today)
        db.completeProject(project.id, now: now)
        #expect(db.todos[todo.id]?.status == .completed)
        #expect(db.openProjects(inArea: nil).isEmpty)
    }

    @Test func quickAddResolvesProjectsAreasAndTags() {
        var db = TaskDatabase()
        let project = db.addProject(Project(title: "Home Reno"))
        let area = db.addArea("Work")
        let parser = QuickAddParser(today: today)

        let a = db.add(parser.parse("Buy paint #Errands /\"home reno\""), today: today)
        #expect(a.projectID == project.id && a.when == .anytime)
        let b = db.add(parser.parse("Expense report /work #errands tomorrow"), today: today)
        #expect(b.areaID == area.id && b.when == .on(day("2026-10-15")))
        #expect(db.tags.count == 1)
        #expect(a.tagIDs == b.tagIDs)

        let c = db.add(parser.parse("Random thought /nowhere"), today: today)
        #expect(c.when == .inbox && c.projectID == nil)
    }

    @Test func completingARepeatingProjectCreatesTheNextOne() {
        var db = TaskDatabase()
        let area = db.addArea("Home")
        let rule = RepeatRule(frequency: .monthly(.day(14)), anchor: today, deadlineOffset: 5)
        let project = db.addProject(Project(title: "Pay bills", areaID: area.id, when: .on(today),
                                            repetition: Repetition(rule: rule, occurrence: today)))
        let heading = db.addHeading("Utilities", toProject: project.id)
        db.add(Todo(title: "Power", projectID: project.id, headingID: heading.id, when: .anytime,
                    checklist: [ChecklistItem(title: "Meter reading", isDone: true)]), today: today)
        let water = db.add(Todo(title: "Water", projectID: project.id, headingID: heading.id, when: .anytime), today: today)
        db.add(Todo(title: "Rent", projectID: project.id, when: .anytime), today: today)
        let gone = db.add(Todo(title: "Old", projectID: project.id, when: .anytime), today: today)
        db.complete(water.id, now: now, timeZone: utc)
        db.trash(gone.id)

        let next = db.completeProject(project.id, now: now, timeZone: utc)
        #expect(db.projects[project.id]?.status == .completed)
        #expect(next?.when == .on(day("2026-11-14")))
        #expect(next?.deadline == day("2026-11-19"))
        #expect(next?.areaID == area.id)
        #expect(next?.repetition?.seriesID == project.repetition?.seriesID)
        #expect(next?.repetition?.index == 2)

        let sections = db.sections(ofProject: next!.id)
        #expect(sections.map { $0.heading?.title } == [nil, "Utilities"])
        #expect(sections.map { $0.todos.map(\.title) } == [["Rent"], ["Power", "Water"]])
        #expect(sections[1].todos[0].checklist.map(\.isDone) == [false])

        // The new instance waits for its start day; completing the old one again does nothing.
        #expect(db.todos(in: .anytime, today: today).isEmpty)
        #expect(db.completeProject(project.id, now: now, timeZone: utc) == nil)
    }

    @Test func snoozeAnHour() {
        var db = TaskDatabase()
        let todo = db.add(Todo(title: "Call", when: .on(today), reminder: TimeOfDay(hour: 9)), today: today)
        db.snooze(todo.id, .oneHour, now: today.date(at: TimeOfDay(hour: 9, minute: 2), timeZone: utc), timeZone: utc)
        #expect(db.todos[todo.id]?.reminder == TimeOfDay(hour: 10, minute: 2))
        #expect(db.todos[todo.id]?.when == .on(today))

        // Late at night it rolls over to tomorrow, keeping This Evening.
        let late = db.add(Todo(title: "Bins", when: .on(today), isEvening: true, reminder: TimeOfDay(hour: 23, minute: 30)), today: today)
        db.snooze(late.id, .oneHour, now: today.date(at: TimeOfDay(hour: 23, minute: 30), timeZone: utc), timeZone: utc)
        #expect(db.todos[late.id]?.when == .on(day("2026-10-15")))
        #expect(db.todos[late.id]?.reminder == TimeOfDay(hour: 0, minute: 30))
        #expect(db.todos[late.id]?.isEvening == true)
    }

    @Test func snoozeUntilTomorrowMovesOnlyThisRepeat() {
        var db = TaskDatabase()
        let rule = RepeatRule(frequency: .weekly([.wednesday]), anchor: today)
        let todo = db.add(Todo(title: "Report", when: .on(today), reminder: TimeOfDay(hour: 8),
                               repetition: Repetition(rule: rule, occurrence: today)), today: today)
        db.snooze(todo.id, .tomorrow, now: now, timeZone: utc)
        #expect(db.todos[todo.id]?.when == .on(day("2026-10-15")))
        #expect(db.todos[todo.id]?.reminder == TimeOfDay(hour: 8))
        #expect(db.todos[todo.id]?.repetition?.rule == rule)

        // Completed to-dos are left alone.
        db.complete(todo.id, now: now, timeZone: utc)
        let before = db.todos[todo.id]
        db.snooze(todo.id, .oneHour, now: now, timeZone: utc)
        #expect(db.todos[todo.id] == before)
    }

    @Test func quickAddInsertsBetweenNeighbours() {
        var db = TaskDatabase()
        let project = db.addProject(Project(title: "Move"))
        let heading = db.addHeading("Packing", toProject: project.id)
        let a = db.add(Todo(title: "a", projectID: project.id, headingID: heading.id, when: .anytime), today: today)
        let b = db.add(Todo(title: "b", projectID: project.id, headingID: heading.id, when: .anytime), today: today)
        let parser = QuickAddParser(today: today)

        db.add(parser.parse("between"), projectID: project.id, headingID: heading.id,
               at: Insertion(after: a.id, before: b.id), today: today)
        db.add(parser.parse("first"), projectID: project.id, headingID: heading.id,
               at: Insertion(after: nil, before: a.id), today: today)
        #expect(db.sections(ofProject: project.id)[1].todos.map(\.title) == ["first", "a", "between", "b"])

        // Text that sends it elsewhere wins; it goes to the end of its new home.
        let other = db.addProject(Project(title: "Garden"))
        let moved = db.add(parser.parse("Rake /garden"), projectID: project.id, headingID: heading.id,
                           at: Insertion(after: a.id, before: b.id), today: today)
        #expect(moved.projectID == other.id && moved.headingID == nil)
    }

    @Test func quickAddInsertsIntoTodayAndEvening() {
        var db = TaskDatabase()
        let a = db.add(Todo(title: "a", when: .on(today)), today: today)
        let b = db.add(Todo(title: "b", when: .on(today)), today: today)
        let night = db.add(Todo(title: "night", when: .on(today), isEvening: true), today: today)
        let parser = QuickAddParser(today: today)

        db.add(parser.parse("top"), defaultWhen: .on(today), at: Insertion(after: nil, before: a.id, inToday: true), today: today)
        db.add(parser.parse("late"), defaultWhen: .on(today), evening: true,
               at: Insertion(after: nil, before: night.id, inToday: true), today: today)
        // Scheduled for tomorrow, so it can't sit between a and b.
        let tomorrow = db.add(parser.parse("later tomorrow"), defaultWhen: .on(today),
                              at: Insertion(after: a.id, before: b.id, inToday: true), today: today)

        let sections = db.todaySections(today: today)
        #expect(sections.today.map(\.title) == ["top", "a", "b"])
        #expect(sections.evening.map(\.title) == ["late", "night"])
        #expect(tomorrow.when == .on(day("2026-10-15")) && tomorrow.todayOrder == nil)
    }

    @Test func trashAndPurge() {
        var db = TaskDatabase()
        let todo = db.add(Todo(title: "x"), today: today)
        db.trash(todo.id, now: now)
        #expect(db.todos(in: .trash, today: today).count == 1)
        db.restore(todo.id)
        #expect(db.todos(in: .inbox, today: today).count == 1)
        db.trash(todo.id, now: now)
        db.purgeTrash(now: now.addingTimeInterval(29 * 86_400))
        #expect(db.todos.count == 1)
        db.purgeTrash(now: now.addingTimeInterval(31 * 86_400))
        #expect(db.todos.isEmpty)
    }

    @Test func search() {
        var db = TaskDatabase()
        let project = db.addProject(Project(title: "Garden"))
        db.add(Todo(title: "Plant tulips", projectID: project.id, when: .anytime), today: today)
        db.add(Todo(title: "Call café", notes: "about the booking"), today: today)
        db.add(Todo(title: "Unrelated"), today: today)
        #expect(db.search("garden").map(\.title) == ["Plant tulips"])
        #expect(db.search("cafe").map(\.title) == ["Call café"])
        #expect(db.search("BOOKING").map(\.title) == ["Call café"])
        #expect(db.search(" ").isEmpty)
    }

    @Test func jsonRoundTrip() throws {
        var db = TaskDatabase()
        let project = db.addProject(Project(title: "P", when: .on(today)))
        db.addHeading("H", toProject: project.id)
        db.addArea("A")
        db.tag(named: "t")
        let rule = RepeatRule(frequency: .monthly(.weekday(ordinal: -1, .friday)), end: .count(4), anchor: today)
        db.add(Todo(title: "x", projectID: project.id, when: .on(today), repetition: Repetition(rule: rule, occurrence: today)), today: today)

        let data = try JSONEncoder().encode(db)
        let decoded = try JSONDecoder().decode(TaskDatabase.self, from: data)
        #expect(decoded == db)
    }
}
