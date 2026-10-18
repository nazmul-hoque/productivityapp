# Productivity App

A calm personal task manager inspired by the Things 3 workflow, built natively for iOS with SwiftUI.
Android comes later.

## Layout

```
Packages/TaskCore/   Swift package with all the app's logic, no UI (tested; also builds on Linux)
  Dates/             LocalDay (calendar day without time zone), Weekday, TimeOfDay
  Models/            Todo, Project, Heading, Area, Tag, ChecklistItem, When
  Lists/             ListClassifier: which smart list(s) a to-do belongs to
  Parsing/           QuickAddParser: "Call Sam tomorrow at 10am #phone /Work !friday"
  Repeat/            RepeatRule + RepeatEngine (fixed / after completion, complete early, reschedule)
  Ordering/          FractionalIndex: sync-friendly ordering keys for drag-and-drop
  Store/             TaskDatabase: the data plus every operation on it, as a plain value
App/Sources/         SwiftUI iOS app (iOS 17+)
  Store/             AppStore (@Observable wrapper), JSON persistence, local reminders, sample data
  Views/             Sidebar, Today, Upcoming, Inbox/Anytime/Someday/Logbook/Trash, Project, Area,
                     to-do editor, quick add, Quick Find
  Components/        Rows, checkbox, progress ring, add button, theme
project.yml          XcodeGen spec that generates the Xcode project
```

All the rules live in `TaskCore` so they can be unit-tested without a simulator.
The app layer only displays them.

## Running the app

1. Install XcodeGen once: `brew install xcodegen`
2. From the repo root: `xcodegen`
3. `open ProductivityApp.xcodeproj`, pick an iPhone simulator, then press Run.

The generated `.xcodeproj` is git-ignored; re-run `xcodegen` after adding or removing files.
To run on a device, set your team under *Signing & Capabilities*.

**Without XcodeGen:** create a new iOS App project in Xcode (SwiftUI, iOS 17), delete its template
Swift files, drag in `App/Sources` and `App/Resources`, then add `Packages/TaskCore` with
*File → Add Package Dependencies… → Add Local…*.

## Tests

```
swift test --package-path Packages/TaskCore
```

Or open `Packages/TaskCore/Package.swift` in Xcode and press ⌘U. CI runs the same tests on every push
(`.github/workflows/core-tests.yml`).

## Status against the spec (Phase 1 — core local app)

Done:
- Data model: areas, projects, headings, to-dos, checklists, tags; start date ("When") kept separate from deadline
- Smart lists: Inbox, Today + This Evening, Upcoming (with repeat previews), Anytime, Someday, Logbook,
  Trash (30-day purge)
- Quick add with natural-language parsing and a live preview
- Repeating to-dos: daily/weekly/monthly/yearly, intervals, fixed schedule or after completion, end
  conditions; completing early; "just this one" vs "this and future" rescheduling
- Local reminders (offline), drag-to-reorder (Today has its own order), swipe to Today/Evening/Someday,
  convert to-do → project, Quick Find search, sample "Get to know the app" project
- Draggable "+" button: drop it between to-dos (or on a heading, the This Evening section or an
  Upcoming day) to add a to-do right there

Next:
- Reminder snooze actions; repeating projects
- Move to SQLite (GRDB) to prepare for sync in Phase 2
- Widgets, share extension, onboarding screens, haptics/motion polish, accessibility pass
