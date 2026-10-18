import Foundation
import Testing
@testable import TaskCore

struct DaybookLinkTests {
    let today = day("2026-10-14")

    @Test(arguments: [
        ("daybook://today", DaybookLink.show(.today)),
        ("daybook://Inbox", .show(.inbox)),
        ("daybook://show?list=someday", .show(.someday)),
        ("daybook://add?title=Call%20Sam%20tomorrow&notes=re%3A%20trip&when=evening",
         .add(title: "Call Sam tomorrow", notes: "re: trip", when: .evening)),
        ("daybook://add?text=Buy%20milk", .add(title: "Buy milk", notes: nil, when: nil)),
        ("daybook://new", .newTodo(prefill: nil)),
        ("daybook://new?title=Draft", .newTodo(prefill: "Draft")),
        ("daybook://search?query=tax", .search("tax")),
        ("daybook://todo/0A0A0A0A-0000-0000-0000-000000000001", .todo(UUID(uuidString: "0A0A0A0A-0000-0000-0000-000000000001")!)),
    ])
    func parses(url: String, link: DaybookLink) {
        #expect(DaybookLink(URL(string: url)!) == link)
        #expect(DaybookLink(link.url) == link)  // and round-trips
    }

    @Test(arguments: ["daybook://add", "daybook://add?title=%20", "daybook://nowhere", "daybook://auth-callback?code=x",
                      "https://example.com/today", "daybook://todo/not-a-uuid", "daybook://show?list=moon"])
    func rejects(url: String) {
        #expect(DaybookLink(URL(string: url)!) == nil)
    }

    @Test func addingReadsTheTitleLikeQuickAdd() {
        var db = TaskDatabase()
        let a = db.add(title: "Call Sam tomorrow at 5pm #phone", notes: "about the trip", when: .someday, today: today)
        #expect(a.title == "Call Sam" && a.when == .on(day("2026-10-15")) && a.reminder == TimeOfDay(hour: 17))
        #expect(a.notes == "about the trip" && db.todos[a.id]?.notes == "about the trip")
        #expect(a.tagIDs.compactMap { db.tags[$0]?.title } == ["phone"])

        let b = db.add(title: "Stretch", notes: nil, when: .evening, today: today)
        #expect(b.when == .on(today) && b.isEvening)
        #expect(db.add(title: "Idea", notes: nil, when: .someday, today: today).when == .someday)
        #expect(db.add(title: "Later", notes: nil, when: .tomorrow, today: today).when == .on(day("2026-10-15")))
        #expect(db.add(title: "Plain", notes: nil, when: nil, today: today).when == .inbox)
    }
}
