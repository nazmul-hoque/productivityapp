import Foundation
import TaskCore

/// First-launch content that also teaches the app's ideas.
enum SampleData {
    static func database(today: LocalDay) -> TaskDatabase {
        var db = TaskDatabase()
        let personal = db.addArea("Personal")
        db.addArea("Work")
        let errands = db.tag(named: "Errands")

        let welcome = db.addProject(Project(title: "Get to know the app", areaID: nil))
        let basics = db.addHeading("The basics", toProject: welcome.id)
        let planning = db.addHeading("Planning your day", toProject: welcome.id)

        func add(_ title: String, notes: String = "", heading: Heading) {
            db.add(Todo(title: title, notes: notes, projectID: welcome.id, headingID: heading.id, when: .anytime), today: today)
        }
        add("Tap the circle to complete a to-do", heading: basics)
        add("Tap a to-do to open it", notes: "Add notes, a checklist, tags, a deadline or a reminder.", heading: basics)
        add("Press + to add a to-do", notes: "Try typing: Call Sam tomorrow at 10am #phone", heading: basics)
        add("Swipe right to move a to-do to Today", heading: planning)
        add("Separate “when” from “deadline”",
            notes: "When is the day you plan to start. A deadline is when it must be done; it pulls the to-do into Today on that day.",
            heading: planning)
        add("Park ideas in Someday", heading: planning)

        db.add(Todo(title: "Plan the week", when: .on(today)), today: today)
        db.add(Todo(title: "Pick up groceries", areaID: personal.id, when: .on(today), isEvening: true, tagIDs: [errands.id]), today: today)
        let weekly = RepeatRule(frequency: .weekly([]), anchor: today.next(.sunday))
        db.add(Todo(title: "Weekly review", when: .on(weekly.anchor),
                    repetition: Repetition(rule: weekly, occurrence: weekly.anchor)), today: today)
        db.add(Todo(title: "Learn to make sourdough", when: .someday), today: today)
        return db
    }
}
