import Foundation
import Testing
@testable import TaskCore

struct CSVTests {
    @Test func parsesQuotedFieldsCommasAndLineBreaks() {
        let text = "\u{FEFF}a,b,c\r\n\"one, two\",\"say \"\"hi\"\"\",\"line 1\nline 2\"\r\n\r\nlast,,\n"
        #expect(CSV.parse(text) == [["a", "b", "c"], ["one, two", "say \"hi\"", "line 1\nline 2"], ["last", "", ""]])
    }

    @Test func writesAndReadsBack() {
        let rows = [["Title", "Notes"], ["Plain", ""], ["Comma, here", "Quote \" and\nnewline"], [" padded ", "x"],
                    ["Just a\nnewline", "cr\ronly"]]
        #expect(CSV.parse(CSV.write(rows)) == rows)
        #expect(CSV.write([["a", "b,c"]]) == "a,\"b,c\"\r\n")
    }
}

struct ExportTests {
    let today = day("2026-10-14")

    func sample() -> TaskDatabase {
        var db = TaskDatabase()
        let work = db.addArea("Work")
        let urgent = db.tag(named: "Urgent")
        let project = db.addProject(Project(title: "Launch", areaID: work.id))
        let heading = db.addHeading("Prep", toProject: project.id)
        let rule = RepeatRule(frequency: .weekly([.monday, .thursday]), interval: 2, anchor: today)
        db.add(Todo(title: "Write, then \"ship\"", notes: "Line 1\nLine 2", projectID: project.id, headingID: heading.id,
                    when: .on(today), isEvening: true, deadline: today.adding(days: 3), reminder: TimeOfDay(hour: 9, minute: 5),
                    repetition: Repetition(rule: rule, occurrence: today), tagIDs: [urgent.id],
                    checklist: [ChecklistItem(title: "Draft", isDone: true), ChecklistItem(title: "Review")]), today: today)
        let done = db.add(Todo(title: "Done thing", areaID: work.id, when: .anytime), today: today)
        db.complete(done.id)
        db.add(Todo(title: "Someday idea", when: .someday), today: today)
        return db
    }

    @Test func backupRoundTripsExactly() throws {
        let db = sample()
        let data = try DaybookExport.json(db)
        #expect(Importer.detect(data) == .daybook)
        #expect(try DaybookExport.readBackup(data) == db)
    }

    @Test func backupRejectsOtherJSONAndNewerVersions() throws {
        #expect(throws: ImportError.unrecognized) { try DaybookExport.readBackup(Data(#"{"hello":1}"#.utf8)) }
        let newer = Data(#"{"format":"daybook-backup","version":99,"exportedAt":0,"data":{}}"#.utf8)
        #expect(throws: ImportError.newerBackup) { try DaybookExport.readBackup(newer) }
    }

    @Test func csvHasOneRowPerTodo() throws {
        let rows = CSV.parse(DaybookExport.csv(sample()))
        #expect(rows.first == DaybookExport.csvColumns)
        #expect(rows.count == 4)
        let row = try #require(rows.first { $0[0] == "Write, then \"ship\"" })
        func value(_ column: String) -> String { row[DaybookExport.csvColumns.firstIndex(of: column)!] }
        #expect(value("Notes") == "Line 1\nLine 2")
        #expect(value("Status") == "open")
        #expect(value("When") == "2026-10-14")
        #expect(value("This Evening") == "yes")
        #expect(value("Deadline") == "2026-10-17")
        #expect(value("Reminder") == "09:05")
        #expect(value("Area") == "Work")
        #expect(value("Project") == "Launch")
        #expect(value("Heading") == "Prep")
        #expect(value("Tags") == "Urgent")
        #expect(value("Checklist") == "[x] Draft\n[ ] Review")
        #expect(value("Repeats") == "Every 2 weeks on Mon, Thu")
        // Open to-dos come first.
        #expect(rows.last?[2] == "completed")
    }

    @Test func repeatSummaries() {
        #expect(RepeatRule(frequency: .daily, anchor: today).summary == "Every day")
        #expect(RepeatRule(frequency: .daily, interval: 3, mode: .afterCompletion, anchor: today).summary == "Every 3 days after completion")
        #expect(RepeatRule(frequency: .monthly(.day(-1)), anchor: today).summary == "Every month on the last day")
        #expect(RepeatRule(frequency: .monthly(.weekday(ordinal: 2, .tuesday)), end: .count(4), anchor: today).summary
                == "Every month on the second Tue, 4 times")
    }
}

struct MergeTests {
    let today = day("2026-10-14")

    @Test func importingABackupTwiceAddsNothingTheSecondTime() throws {
        var source = TaskDatabase()
        let project = source.addProject(Project(title: "P"))
        source.addHeading("H", toProject: project.id)
        source.add(Todo(title: "a", projectID: project.id, when: .anytime), today: today)
        source.add(Todo(title: "b", when: .inbox, tagIDs: [source.tag(named: "x").id]), today: today)

        var db = TaskDatabase()
        let first = db.merge(source, today: today)
        #expect(first.todos == 2 && first.projects == 1 && first.tags == 1 && first.skipped == 0)
        let second = db.merge(source, today: today)
        #expect(second.todos == 0 && second.projects == 0 && second.skipped == 3)
        #expect(db.todos.count == 2 && db.headings.count == 1)
    }

    @Test func reusesAreasAndTagsByName() {
        var db = TaskDatabase()
        let work = db.addArea("Work")
        let tag = db.tag(named: "Errands")

        var imported = TaskDatabase()
        let importedArea = imported.addArea("work")
        imported.add(Todo(title: "Call", areaID: importedArea.id, when: .anytime, tagIDs: [imported.tag(named: "errands").id]), today: today)
        let summary = db.merge(imported, today: today)

        #expect(summary.areas == 0 && summary.tags == 0 && summary.todos == 1)
        let todo = db.todos.values.first { $0.title == "Call" }!
        #expect(todo.areaID == work.id)
        #expect(todo.tagIDs == [tag.id])
    }

    @Test func keepsOrderWithinAProject() {
        var imported = TaskDatabase()
        let project = imported.addProject(Project(title: "P"))
        for title in ["one", "two", "three"] {
            imported.add(Todo(title: title, projectID: project.id, when: .anytime), today: today)
        }
        var db = TaskDatabase()
        db.merge(imported, today: today)
        #expect(db.sections(ofProject: project.id).first?.todos.map(\.title) == ["one", "two", "three"])
    }
}

struct TodoistImportTests {
    let today = day("2026-10-14")  // Wednesday

    let csv = """
        TYPE,CONTENT,DESCRIPTION,PRIORITY,INDENT,AUTHOR,RESPONSIBLE,DATE,DATE_LANG,TIMEZONE,DURATION,DURATION_UNIT,DEADLINE,DEADLINE_LANG
        task,Book flights @travel,Window seat,4,1,Sam (1),,tomorrow,en,America/Toronto,,,Oct 20,en
        task,Passport photos,,1,2,Sam (1),,,en,America/Toronto,,,,
        task,Renew passport,,1,2,Sam (1),,,en,America/Toronto,,,,
        note,Check the embassy site,,,,Sam (1),,,,,,,,
        ,,,,,,,,,,,,,
        section,Packing,,,,,,,,,,,,
        task,Water plants,,2,1,Sam (1),,every monday at 9am,en,America/Toronto,,,,
        task,Laundry,,1,1,Sam (1),,every! 3 days,en,America/Toronto,,,,
        task,Weird date,,1,1,Sam (1),,next blue moon,en,America/Toronto,,,,
        """

    @Test func importsTasksSectionsSubtasksAndNotes() throws {
        let data = Data(csv.utf8)
        #expect(Importer.detect(data) == .todoist)
        let (format, db) = try Importer.read(data, fileName: "Trip.csv", today: today)
        #expect(format == .todoist)
        #expect(db.projects.values.map(\.title) == ["Trip"])
        let project = db.projects.values.first!
        let sections = db.sections(ofProject: project.id)
        #expect(sections.map { $0.heading?.title } == [nil, "Packing"])
        #expect(sections[0].todos.map(\.title) == ["Book flights"])
        #expect(sections[1].todos.map(\.title) == ["Water plants", "Laundry", "Weird date"])

        let flights = sections[0].todos[0]
        #expect(flights.notes == "Window seat\nCheck the embassy site")
        #expect(flights.when == .on(day("2026-10-15")))
        #expect(flights.deadline == day("2026-10-20"))
        #expect(flights.checklist.map(\.title) == ["Passport photos", "Renew passport"])
        #expect(Set(flights.tagIDs.compactMap { db.tags[$0]?.title }) == ["travel", "Priority 1"])

        let plants = sections[1].todos[0]
        #expect(plants.repetition?.rule.frequency == .weekly([.monday]))
        #expect(plants.when == .on(day("2026-10-19")))
        #expect(plants.reminder == TimeOfDay(hour: 9))
        #expect(sections[1].todos[1].repetition?.rule.mode == .afterCompletion)
        #expect(sections[1].todos[1].repetition?.rule.interval == 3)
        #expect(sections[1].todos[2].when == .anytime)
        #expect(sections[1].todos[2].notes == "Date in Todoist: next blue moon")
    }

    @Test(arguments: [
        ("every day", RepeatRule.Frequency.daily, 1), ("daily", .daily, 1), ("every 2 weeks", .weekly([]), 2),
        ("every other month", .monthly(.day(14)), 2), ("every weekday", .weekly([.monday, .tuesday, .wednesday, .thursday, .friday]), 1),
        ("every mon, fri", .weekly([.monday, .friday]), 1), ("every 15th", .monthly(.day(15)), 1), ("every year", .yearly(month: 10, day: 14), 1),
    ])
    func recurrence(text: String, frequency: RepeatRule.Frequency, interval: Int) {
        let rule = RecurrenceText.rule(from: text, today: today)
        #expect(rule?.frequency == frequency)
        #expect(rule?.interval == interval)
    }

    @Test func notRecurrence() {
        #expect(RecurrenceText.rule(from: "tomorrow", today: today) == nil)
        #expect(RecurrenceText.rule(from: "every", today: today) == nil)
    }
}

struct TickTickImportTests {
    let csv = """
        "Date: 2026-10-14+0000"
        "Version: 7.1"
        "Status:
        0 Normal
        1 Completed
        2 Archived"
        "Folder Name","List Name","Title","Kind","Tags","Content","Is Check list","Start Date","Due Date","Reminder","Repeat","Priority","Status","Created Time","Completed Time","Order","Timezone","Is All Day","Is Floating","Column Name","Column Order","View Mode","taskId","parentId"
        "Life","Home","Fix tap","TEXT","diy, #weekend","Washer is worn","N","","2026-10-16T00:00:00+0000","","","0","0","2026-10-01T10:00:00+0000","","1","UTC","true","false","To do","","kanban","t1",""
        "Life","Home","Buy washer","TEXT","","","N","","","","","0","0","2026-10-01T10:00:00+0000","","2","UTC","true","false","","","list","t2","t1"
        "","Inbox","Call dentist","TEXT","","","N","2026-10-15T14:30:00+0000","","","","0","0","2026-10-02T10:00:00+0000","","1","America/Toronto","false","false","","","list","t3",""
        "Work","Weekly","Report","CHECKLIST","","▪Draft
        ▫Send","Y","2026-10-12T00:00:00+0000","2026-10-14T00:00:00+0000","","RRULE:FREQ=WEEKLY;INTERVAL=1;BYDAY=MO","0","0","2026-09-01T10:00:00+0000","","1","UTC","true","false","","","list","t4",""
        "Work","Weekly","Old task","TEXT","","","N","","","","","0","2","2026-09-01T10:00:00+0000","2026-09-05T10:00:00+0000","2","UTC","true","false","","","list","t5",""
        """

    @Test func importsFoldersListsColumnsSubtasksAndRepeats() throws {
        let data = Data(csv.utf8)
        #expect(Importer.detect(data) == .tickTick)
        let (_, db) = try Importer.read(data, fileName: "backup.csv", today: day("2026-10-14"))

        #expect(Set(db.areas.values.map(\.title)) == ["Life", "Work"])
        #expect(Set(db.projects.values.map(\.title)) == ["Home", "Weekly"])  // Inbox isn't a project

        let tap = db.todos.values.first { $0.title == "Fix tap" }!
        #expect(tap.when == .on(day("2026-10-16")))
        #expect(tap.reminder == nil)  // all-day
        #expect(tap.notes == "Washer is worn")
        #expect(tap.headingID.flatMap { db.headings[$0]?.title } == "To do")
        #expect(tap.checklist.map(\.title) == ["Buy washer"])
        #expect(Set(tap.tagIDs.compactMap { db.tags[$0]?.title }) == ["diy", "weekend"])
        #expect(db.todos.values.contains { $0.title == "Buy washer" } == false)

        let dentist = db.todos.values.first { $0.title == "Call dentist" }!
        #expect(dentist.projectID == nil && dentist.areaID == nil)
        #expect(dentist.when == .on(day("2026-10-15")))
        #expect(dentist.reminder == TimeOfDay(hour: 10, minute: 30))  // 14:30 UTC in Toronto

        let report = db.todos.values.first { $0.title == "Report" }!
        #expect(report.checklist == [ChecklistItem(id: report.checklist[0].id, title: "Draft", isDone: true),
                                     ChecklistItem(id: report.checklist[1].id, title: "Send")])
        #expect(report.when == .on(day("2026-10-12")))
        #expect(report.deadline == day("2026-10-14"))
        #expect(report.repetition?.rule.frequency == .weekly([.monday]))

        let old = db.todos.values.first { $0.title == "Old task" }!
        #expect(old.status == .completed)
    }

    @Test func rrules() {
        let anchor = day("2026-10-14")
        #expect(RRule.rule(from: "RRULE:FREQ=DAILY;INTERVAL=2", anchor: anchor)?.interval == 2)
        #expect(RRule.rule(from: "FREQ=MONTHLY;BYMONTHDAY=-1", anchor: anchor)?.frequency == .monthly(.day(-1)))
        #expect(RRule.rule(from: "FREQ=MONTHLY;BYDAY=2TU", anchor: anchor)?.frequency == .monthly(.weekday(ordinal: 2, .tuesday)))
        #expect(RRule.rule(from: "FREQ=WEEKLY;COUNT=3", anchor: anchor)?.end == .count(3))
        #expect(RRule.rule(from: "FREQ=WEEKLY;UNTIL=20261231T000000Z", anchor: anchor)?.end == .until(day("2026-12-31")))
        #expect(RRule.rule(from: "FREQ=HOURLY", anchor: anchor) == nil)
    }
}

struct GoogleTasksImportTests {
    let json = """
        {"kind":"tasks#taskLists","items":[
          {"kind":"tasks#taskList","id":"L1","title":"My Tasks","items":[
            {"kind":"tasks#task","id":"a","title":"Pay rent","notes":"Landlord","status":"needsAction","due":"2026-11-01T00:00:00.000Z","position":"00000000000000000001"},
            {"kind":"tasks#task","id":"b","title":"Groceries","status":"needsAction","position":"00000000000000000000"},
            {"kind":"tasks#task","id":"c","title":"Milk","status":"completed","parent":"b","completed":"2026-10-10T08:00:00.000Z","position":"00000000000000000000"},
            {"kind":"tasks#task","id":"d","title":"Gone","status":"needsAction","deleted":true},
            {"kind":"tasks#task","id":"e","title":"Filed taxes","status":"completed","completed":"2026-04-30T12:00:00.000Z","position":"00000000000000000002"}
          ]},
          {"kind":"tasks#taskList","id":"L2","title":"Empty","items":[]}
        ]}
        """

    @Test func importsListsSubtasksAndDueDates() throws {
        let data = Data(json.utf8)
        #expect(Importer.detect(data) == .googleTasks)
        let (_, db) = try Importer.read(data, fileName: "Tasks.json", today: day("2026-10-14"))
        #expect(db.projects.values.map(\.title) == ["My Tasks"])  // the empty list is skipped
        let project = db.projects.values.first!
        #expect(db.sections(ofProject: project.id).first?.todos.map(\.title) == ["Groceries", "Pay rent"])

        let rent = db.todos.values.first { $0.title == "Pay rent" }!
        #expect(rent.when == .on(day("2026-11-01")) && rent.notes == "Landlord")
        let groceries = db.todos.values.first { $0.title == "Groceries" }!
        #expect(groceries.checklist.map(\.title) == ["Milk"] && groceries.checklist[0].isDone)
        #expect(db.todos.values.first { $0.title == "Filed taxes" }?.status == .completed)
        #expect(db.todos.values.contains { $0.title == "Gone" } == false)
    }
}

struct RemindersImportTests {
    @Test func listsBecomeProjects() {
        let rule = RepeatRule(frequency: .weekly([]), anchor: day("2000-01-01"))
        let items = [
            ReminderItem(title: "Call mum", listName: "Family", day: day("2026-10-15"), time: TimeOfDay(hour: 18)),
            ReminderItem(title: "Bins", listName: "Family", day: day("2026-10-16"), repeatRule: rule),
            ReminderItem(title: "Read this", listName: "Reading", url: URL(string: "https://example.com")!),
            ReminderItem(title: "Done", listName: "Reading", isCompleted: true),
            ReminderItem(title: "  ", listName: "Reading"),
        ]
        let db = RemindersImport.database(from: items, today: day("2026-10-14"))
        #expect(Set(db.projects.values.map(\.title)) == ["Family", "Reading"])
        #expect(db.todos.count == 4)
        let call = db.todos.values.first { $0.title == "Call mum" }!
        #expect(call.when == .on(day("2026-10-15")) && call.reminder == TimeOfDay(hour: 18))
        let bins = db.todos.values.first { $0.title == "Bins" }!
        #expect(bins.repetition?.rule.anchor == day("2026-10-16"))
        #expect(db.todos.values.first { $0.title == "Read this" }?.notes == "https://example.com")
        #expect(db.todos.values.first { $0.title == "Done" }?.status == .completed)
    }
}

struct DetectionTests {
    @Test func unknownFilesAreRejected() {
        #expect(Importer.detect(Data("just some text".utf8)) == nil)
        #expect(Importer.detect(Data(#"{"other":"json"}"#.utf8)) == nil)
        #expect(throws: ImportError.unrecognized) {
            try Importer.read(Data("a,b\n1,2".utf8), fileName: "x.csv", today: day("2026-10-14"))
        }
    }
}
