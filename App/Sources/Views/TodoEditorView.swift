import SwiftUI
import TaskCore

/// The expanded to-do: notes, checklist, when, reminder, deadline, repeat, tags and list.
struct TodoEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let original: Todo
    @State private var draft: Todo
    @State private var container: Container
    @State private var hasDeadline: Bool
    @State private var hasReminder: Bool
    @State private var reminderTime: TimeOfDay
    @State private var repeatKind: RepeatKind
    @State private var repeatInterval: Int
    @State private var repeatMode: RepeatRule.Mode
    @State private var newChecklistItem = ""
    @State private var newTag = ""
    @State private var askingRepeatScope = false

    init(todo: Todo) {
        original = todo
        _draft = State(initialValue: todo)
        _container = State(initialValue: Container(todo))
        _hasDeadline = State(initialValue: todo.deadline != nil)
        _hasReminder = State(initialValue: todo.reminder != nil)
        _reminderTime = State(initialValue: todo.reminder ?? TimeOfDay(hour: 9))
        _repeatKind = State(initialValue: RepeatKind(todo.repetition?.rule.frequency))
        _repeatInterval = State(initialValue: todo.repetition?.rule.interval ?? 1)
        _repeatMode = State(initialValue: todo.repetition?.rule.mode ?? .fixed)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("New To-Do", text: $draft.title)
                        .font(.title3.weight(.semibold))
                    TextField("Notes", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...12)
                }

                checklistSection
                whenSection
                repeatSection
                tagsSection

                Section {
                    Picker("List", selection: $container) {
                        Text("Inbox").tag(Container.none)
                        ForEach(store.db.sortedAreas) { Text($0.title).tag(Container.area($0.id)) }
                        ForEach(openProjects) { Text($0.title).tag(Container.project($0.id)) }
                    }
                }

                Section {
                    if original.projectID == nil && original.status == .open {
                        Button { convertToProject() } label: { Label("Convert to Project", systemImage: "circle.dashed") }
                    }
                    Button(role: .destructive) {
                        store.trash(original.id)
                        dismiss()
                    } label: {
                        Label("Delete To-Do", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { done() }.bold() }
            }
            .onChange(of: hasDeadline) { _, on in
                if on && draft.deadline == nil { draft.deadline = store.today.adding(days: 1) }
            }
            .confirmationDialog("This is a repeating to-do", isPresented: $askingRepeatScope, titleVisibility: .visible) {
                Button("Just This One") { save(updatingSeries: false) }
                Button("This and Future To-Dos") { save(updatingSeries: true) }
            } message: {
                Text("Move only this one, or change the schedule of the series?")
            }
        }
    }

    // MARK: - Sections

    private var checklistSection: some View {
        Section("Checklist") {
            ForEach($draft.checklist) { $item in
                HStack {
                    Button { item.isDone.toggle() } label: {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isDone ? Color.accentColor : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    TextField("Item", text: $item.title)
                        .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
                }
            }
            .onDelete { draft.checklist.remove(atOffsets: $0) }
            .onMove { draft.checklist.move(fromOffsets: $0, toOffset: $1) }

            TextField("Add item", text: $newChecklistItem)
                .submitLabel(.next)
                .onSubmit {
                    let title = newChecklistItem.trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return }
                    draft.checklist.append(ChecklistItem(title: title))
                    newChecklistItem = ""
                }
        }
    }

    private var whenSection: some View {
        Section {
            Menu {
                WhenMenuItems(today: store.today) { when, evening in
                    draft.when = when
                    draft.isEvening = evening
                }
                Button { draft.when = .on(store.today.adding(days: 2)) } label: {
                    Label("Pick a Date…", systemImage: "calendar")
                }
                Button { draft.when = .inbox } label: { Label("Clear", systemImage: "xmark") }
            } label: {
                LabeledContent("When", value: whenLabel)
            }

            if case .on(let day) = draft.when {
                DatePicker("Start", selection: startBinding, displayedComponents: .date)
                if day <= store.today {
                    Toggle("This Evening", isOn: $draft.isEvening)
                }
            }

            Toggle("Reminder", isOn: $hasReminder)
            if hasReminder {
                DatePicker("Time", selection: reminderBinding, displayedComponents: .hourAndMinute)
            }

            Toggle("Deadline", isOn: $hasDeadline)
            if hasDeadline {
                DatePicker("Due", selection: dayBinding($draft.deadline, default: store.today), displayedComponents: .date)
            }
        }
    }

    private var repeatSection: some View {
        Section {
            RepeatFields(kind: $repeatKind, interval: $repeatInterval, mode: $repeatMode)
        }
    }

    private var tagsSection: some View {
        Section("Tags") {
            ForEach(store.db.sortedTags) { tag in
                Button {
                    if draft.tagIDs.contains(tag.id) { draft.tagIDs.remove(tag.id) } else { draft.tagIDs.insert(tag.id) }
                } label: {
                    HStack {
                        Text(tag.title).foregroundStyle(.primary)
                        Spacer()
                        if draft.tagIDs.contains(tag.id) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            TextField("New tag", text: $newTag)
                .onSubmit {
                    let title = newTag.trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return }
                    var created: Tag?
                    store.perform { created = $0.tag(named: title) }
                    if let created { draft.tagIDs.insert(created.id) }
                    newTag = ""
                }
        }
    }

    // MARK: - Helpers

    private var openProjects: [Project] {
        store.db.projects.values
            .filter { !$0.isDeleted && $0.status == .open }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var whenLabel: String {
        switch draft.when {
        case .inbox: "No date"
        case .anytime: "Anytime"
        case .someday: "Someday"
        case .on(let day) where day <= store.today: draft.isEvening ? "This Evening" : "Today"
        case .on(let day): DayLabel.short(day, today: store.today)
        }
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: {
                if case .on(let day) = draft.when { return day.date() }
                return store.today.date()
            },
            set: { draft.when = .on(LocalDay($0)) }
        )
    }

    private var reminderBinding: Binding<Date> {
        Binding(
            get: { store.today.date(at: reminderTime) },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                reminderTime = TimeOfDay(hour: c.hour ?? 9, minute: c.minute ?? 0)
            }
        )
    }

    /// The edited repeat settings as a rule, starting on `anchor`.
    private func repetition(anchor: LocalDay) -> Repetition? {
        guard repeatKind != .never else { return nil }
        if let existing = original.repetition,
           RepeatKind(existing.rule.frequency) == repeatKind,
           existing.rule.interval == repeatInterval,
           existing.rule.mode == repeatMode {
            var kept = existing
            kept.rule.reminder = hasReminder ? reminderTime : nil
            return kept  // Unchanged; keep custom details like specific weekdays.
        }
        let rule = RepeatRule(frequency: repeatKind.frequency(anchor: anchor), interval: repeatInterval, mode: repeatMode, anchor: anchor,
                              reminder: hasReminder ? reminderTime : nil)
        return Repetition(seriesID: original.repetition?.seriesID ?? UUID(), rule: rule, occurrence: anchor)
    }

    private func done() {
        let repeatUnchanged = original.repetition != nil
            && RepeatKind(original.repetition?.rule.frequency) == repeatKind
            && original.repetition?.rule.interval == repeatInterval
            && original.repetition?.rule.mode == repeatMode
        if repeatUnchanged && draft.when != original.when, case .on = draft.when {
            askingRepeatScope = true
        } else {
            save(updatingSeries: false)
        }
    }

    private func save(updatingSeries: Bool) {
        var updated = draft
        updated.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.checklist.removeAll { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }
        if !hasDeadline { updated.deadline = nil }
        updated.reminder = hasReminder ? reminderTime : nil

        // Reminders and repeats need a start day.
        if hasReminder || repeatKind != .never, !updated.when.isScheduled {
            updated.when = .on(store.today)
        }
        if case .on(let day) = updated.when {
            updated.repetition = repetition(anchor: day)
        } else {
            updated.repetition = nil
        }

        let id = original.id
        let today = store.today
        let container = container
        let originalContainer = Container(original)
        store.perform { db in
            // Write everything except the start, then schedule so Today ordering is kept.
            var fields = updated
            fields.when = original.when
            fields.isEvening = original.isEvening
            db.update(fields)
            if container != originalContainer {
                switch container {
                case .none: db.move(id, toProject: nil)
                case .project(let projectID): db.move(id, toProject: projectID)
                case .area(let areaID): db.move(id, toProject: nil, area: areaID)
                }
            }
            if updatingSeries, case .on(let day) = updated.when {
                db.rescheduleSeries(id, to: day, today: today)
            }
            db.schedule(id, updated.when, evening: updated.isEvening, today: today)
        }
        dismiss()
    }

    private func convertToProject() {
        let id = original.id
        let today = store.today
        var updated = draft
        updated.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        store.perform { db in
            db.update(updated)
            _ = db.convertToProject(id, today: today)
        }
        dismiss()
    }
}

extension When {
    var isScheduled: Bool {
        if case .on = self { return true }
        return false
    }
}
