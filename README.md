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
Packages/TaskCore/Sources/TaskStore/
                     SQLite persistence (GRDB): schema, row mapping, diff-based saves
App/Sources/         SwiftUI iOS app (iOS 17+)
  Store/             AppStore (@Observable wrapper), database location, local reminders, sample data
  Views/             Sidebar, Today, Upcoming, Inbox/Anytime/Someday/Logbook/Trash, Project, Area,
                     to-do editor, quick add, Quick Find
  Components/        Rows, checkbox, progress ring, add button, theme
Widget/              Today widget (WidgetKit extension; reads the shared database read-only)
Share/               Share extension: save a link or text from any app as a to-do
Shared/              Code compiled into both the app and the widget (App Group database location)
project.yml          XcodeGen spec that generates the Xcode project
```

All the rules live in `TaskCore` so they can be unit-tested without a simulator.
The app layer only displays them.

## Storage

Data is stored on the device in SQLite, in the App Group container
(`group.com.nazmulhoque.productivityapp`) at `Database/tasks.sqlite`, so widgets and the share
extension can open the same file. The app works on an in-memory `TaskDatabase`; after each change
`TaskStore` writes only the rows that changed, in one transaction (WAL mode, so other processes can
read while the app writes). On first launch after upgrading, the old `database.json` is imported
and kept as `database.migrated.json`.

To run on a device, Xcode needs to register the App Group for your team: in *Signing &
Capabilities*, pick your team for the `ProductivityApp`, `ProductivityWidgets` and `ProductivityShare` targets; each
target's App Groups capability comes from its `.entitlements` file.

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
- Repeating projects: completing one creates the next instance with the same headings and to-dos
- Local reminders (offline) with Snooze 1 Hour / Tomorrow / Complete buttons on the notification,
  drag-to-reorder (Today has its own order), swipe to Today/Evening/Someday,
  convert to-do → project, Quick Find search, sample "Get to know the app" project
- SQLite storage (GRDB) in the App Group container, ready for widgets and sync
- Today widget (small, medium, large): check off to-dos right from it; refreshes after every change
  and at midnight; tap to open Today. The app picks up the widget's changes when it comes to the foreground.
  On the Lock Screen: circular (count), rectangular (count and first to-dos) and inline
- Share extension: share a page or text from any app to add it to the Inbox or Today (page title as the
  title, link in the notes)
- Draggable "+" button: drop it between to-dos (or on a heading, the This Evening section or an
  Upcoming day) to add a to-do right there; the list scrolls when you hold it near the top or bottom
- Upcoming shows projects on their start day (or deadline) and previews of repeating ones
- Polish: app icon (light, dark, tinted; `scripts/make_icon.swift`), first-launch onboarding, VoiceOver
  (rows read as one sentence with Complete as an action), Dynamic Type, haptics, Reduce Motion

Phase 1 is feature-complete. Known limits, for Phase 2:
- Deletions remove rows outright; sync will need tombstones
- If the app and the widget change the same to-do before the app saves, the app's version wins
