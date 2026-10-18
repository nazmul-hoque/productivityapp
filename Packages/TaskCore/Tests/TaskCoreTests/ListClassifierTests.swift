import Foundation
import Testing
@testable import TaskCore

struct ListClassifierTests {
    let today = day("2026-10-14")

    func lists(_ todo: Todo, projects: [Project] = []) -> Set<SmartList> {
        ListClassifier(today: today, projects: Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })).lists(for: todo)
    }

    @Test func basicBuckets() {
        #expect(lists(Todo(title: "a", when: .inbox)) == [.inbox])
        #expect(lists(Todo(title: "a", when: .anytime)) == [.anytime])
        #expect(lists(Todo(title: "a", when: .someday)) == [.someday])
    }

    @Test func scheduledDays() {
        #expect(lists(Todo(title: "a", when: .on(today))) == [.today, .anytime])
        #expect(lists(Todo(title: "a", when: .on(day("2026-10-01")))) == [.today, .anytime])
        #expect(lists(Todo(title: "a", when: .on(day("2026-10-15")))) == [.upcoming])
    }

    @Test func deadlinesPullIntoTodayOrUpcoming() {
        #expect(lists(Todo(title: "a", when: .anytime, deadline: today)) == [.anytime, .today])
        #expect(lists(Todo(title: "a", when: .someday, deadline: day("2026-10-10"))) == [.someday, .today])
        #expect(lists(Todo(title: "a", when: .anytime, deadline: day("2026-10-20"))) == [.anytime, .upcoming])
        #expect(lists(Todo(title: "a", when: .on(today), deadline: day("2026-10-20"))) == [.today, .anytime])
    }

    @Test func closedAndDeleted() {
        #expect(lists(Todo(title: "a", status: .completed)) == [.logbook])
        #expect(lists(Todo(title: "a", status: .canceled)) == [.logbook])
        #expect(lists(Todo(title: "a", status: .completed, deletedAt: Date())) == [.trash])
    }

    @Test func inboxItemInAProjectIsAnytime() {
        let project = Project(title: "P")
        #expect(lists(Todo(title: "a", projectID: project.id, when: .inbox), projects: [project]) == [.anytime])
        #expect(lists(Todo(title: "a", areaID: UUID(), when: .inbox)) == [.anytime])
    }

    @Test func projectStateGatesItsTodos() {
        let someday = Project(title: "S", when: .someday)
        #expect(lists(Todo(title: "a", projectID: someday.id, when: .anytime), projects: [someday]) == [.someday])
        // An explicit date still wins.
        #expect(lists(Todo(title: "a", projectID: someday.id, when: .on(today)), projects: [someday]) == [.today, .anytime])

        let later = Project(title: "L", when: .on(day("2026-11-01")))
        #expect(lists(Todo(title: "a", projectID: later.id, when: .anytime), projects: [later]).isEmpty)

        let done = Project(title: "D", status: .completed)
        #expect(lists(Todo(title: "a", projectID: done.id, when: .anytime), projects: [done]) == [.logbook])

        let trashed = Project(title: "T", deletedAt: Date())
        #expect(lists(Todo(title: "a", projectID: trashed.id, when: .anytime), projects: [trashed]) == [.trash])
    }

    @Test func todaySections() {
        let classifier = ListClassifier(today: today)
        #expect(classifier.todaySection(for: Todo(title: "a", when: .on(today), isEvening: true)) == .evening)
        #expect(classifier.todaySection(for: Todo(title: "a", when: .on(today))) == .today)
        // An evening flag only applies to items scheduled for today.
        #expect(classifier.todaySection(for: Todo(title: "a", when: .anytime, isEvening: true, deadline: today)) == .today)
        #expect(classifier.todaySection(for: Todo(title: "a", when: .anytime)) == nil)
    }

    @Test func upcomingDay() {
        let classifier = ListClassifier(today: today)
        #expect(classifier.upcomingDay(for: Todo(title: "a", when: .on(day("2026-10-20")), deadline: day("2026-10-25"))) == day("2026-10-20"))
        #expect(classifier.upcomingDay(for: Todo(title: "a", when: .anytime, deadline: day("2026-10-25"))) == day("2026-10-25"))
        #expect(classifier.upcomingDay(for: Todo(title: "a", when: .on(today))) == nil)
    }
}
