import SwiftUI
import TaskCore

/// What a row shows depends on the list it is in.
enum RowContext {
    case today, upcoming, list, project, logbook, trash
}

struct TodoRow: View {
    @Environment(AppStore.self) private var store
    let todo: Todo
    var context: RowContext = .list
    /// A future instance of a repeating to-do, shown in Upcoming but not yet real.
    var isPreview = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isChecking = false
    @State private var showingEditor = false
    @State private var completions = 0

    private var isChecked: Bool { isChecking || todo.status.isClosed }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CheckCircle(isChecked: isChecked, isCanceled: todo.status == .canceled, action: toggle)
                .padding(.top, 1)
                .disabled(isPreview || context == .trash)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if showsTodayStar {
                        Image(systemName: todo.isEvening ? "moon.fill" : "star.fill")
                            .font(.caption)
                            .foregroundStyle(todo.isEvening ? Theme.evening : SmartList.today.tint)
                    }
                    Text(todo.title.isEmpty ? "New To-Do" : todo.title)
                        .foregroundStyle(todo.title.isEmpty || isChecked ? Color.secondary : Color.primary)
                        .strikethrough(todo.status == .canceled)
                }
                if !details.isEmpty {
                    Text(details.map(\.shown).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                }
            }

            Spacer(minLength: 0)

            if let deadline = todo.deadline, todo.status == .open {
                Label(DayLabel.short(deadline, today: store.today), systemImage: "flag.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(deadline <= store.today ? Theme.deadline : Color.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(isPreview ? 0.5 : 1)
        .contentShape(Rectangle())
        // VoiceOver reads the row as one sentence; the check box becomes a named action.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenText)
        .accessibilityValue(todo.status == .canceled ? "Canceled" : isChecked ? "Completed" : "")
        .accessibilityAddTraits(isPreview ? [] : .isButton)
        .accessibilityHint(isPreview ? "" : "Opens the to-do")
        .accessibilityAction { if !isPreview { showingEditor = true } }
        .accessibilityActions {
            if !isPreview && context != .trash {
                Button(todo.status.isClosed ? "Mark as Open" : "Complete", action: toggle)
            }
        }
        .onTapGesture { if !isPreview { showingEditor = true } }
        .sheet(isPresented: $showingEditor) {
            TodoEditorView(todo: todo)
        }
        .sensoryFeedback(.success, trigger: completions)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if todo.status == .open && !isPreview {
                Button { Haptics.selection(); store.schedule(todo.id, .on(store.today)) } label: { Label("Today", systemImage: "star.fill") }
                    .tint(SmartList.today.tint)
                Button { Haptics.selection(); store.schedule(todo.id, .on(store.today), evening: true) } label: { Label("Evening", systemImage: "moon.fill") }
                    .tint(Theme.evening)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if context == .trash {
                Button { Haptics.selection(); store.restore(todo.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .tint(.blue)
            } else if !isPreview {
                Button(role: .destructive) { Haptics.impact(); store.trash(todo.id) } label: { Label("Delete", systemImage: "trash") }
                if todo.status == .open {
                    Button { Haptics.selection(); store.schedule(todo.id, .someday) } label: { Label("Someday", systemImage: "archivebox") }
                        .tint(SmartList.someday.tint)
                }
            }
        }
        .contextMenu {
            if todo.status == .open && !isPreview {
                WhenMenuItems(today: store.today) { when, evening in store.schedule(todo.id, when, evening: evening) }
                Divider()
                Button { store.cancel(todo.id) } label: { Label("Cancel To-Do", systemImage: "xmark.square") }
            }
            if todo.status.isClosed && context != .trash {
                Button { store.reopen(todo.id) } label: { Label("Mark as Open", systemImage: "arrow.uturn.backward") }
            }
            if context != .trash && !isPreview {
                Button(role: .destructive) { store.trash(todo.id) } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private var showsTodayStar: Bool {
        guard todo.status == .open, context == .list || context == .project else { return false }
        return store.classifier.isIn(.today, todo)
    }

    /// Secondary line: container, tags, checklist progress, notes and repeat indicators, each
    /// as shown and as VoiceOver says it.
    private var details: [(shown: String, spoken: String)] {
        var parts: [(shown: String, spoken: String)] = []
        func add(_ shown: String, spoken: String? = nil) { parts.append((shown, spoken ?? shown)) }
        if context != .project, let container = store.title(of: Container(todo)) {
            add(container)
        }
        if context == .list, case .on(let day) = todo.when, day > store.today {
            add(DayLabel.short(day, today: store.today), spoken: "starts " + DayLabel.short(day, today: store.today))
        }
        let tags = todo.tagIDs.compactMap { store.db.tags[$0]?.title }.sorted()
        if !tags.isEmpty { add(tags.joined(separator: ", ")) }
        if !todo.checklist.isEmpty {
            let done = todo.checklist.filter(\.isDone).count
            add("\(done)/\(todo.checklist.count)", spoken: "\(done) of \(todo.checklist.count) checklist items done")
        }
        if todo.repetition != nil { add("↻", spoken: "repeats") }
        if !todo.notes.isEmpty { add("✎", spoken: "has notes") }
        if let reminder = todo.reminder, todo.status == .open {
            add(reminder.formatted, spoken: "reminder at " + reminder.formatted)
        }
        return parts
    }

    /// The whole row for VoiceOver, e.g. "Call Sam, Today, Work, phone, reminder at 10:00 AM".
    private var spokenText: String {
        var parts = [todo.title.isEmpty ? "New To-Do" : todo.title]
        if showsTodayStar { parts.append(todo.isEvening ? "This Evening" : "Today") }
        if let deadline = todo.deadline, todo.status == .open {
            parts.append("due " + DayLabel.short(deadline, today: store.today))
        }
        parts += details.map(\.spoken)
        if isPreview { parts.append("future repeat") }
        return parts.joined(separator: ", ")
    }

    private func toggle() {
        if todo.status.isClosed {
            store.reopen(todo.id)
            return
        }
        // Show the check first, then let the row leave the list.
        isChecking = true
        completions += 1
        let id = todo.id
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            store.complete(id)
            isChecking = false
        }
    }
}

extension TimeOfDay {
    /// Localized, e.g. "9:30 AM".
    var formatted: String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        let date = Calendar.current.date(from: components) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// The standard "When" choices, for menus.
struct WhenMenuItems: View {
    let today: LocalDay
    let apply: (When, Bool) -> Void

    var body: some View {
        Button { apply(.on(today), false) } label: { Label("Today", systemImage: "star.fill") }
        Button { apply(.on(today), true) } label: { Label("This Evening", systemImage: "moon.fill") }
        Button { apply(.on(today.adding(days: 1)), false) } label: { Label("Tomorrow", systemImage: "sunrise.fill") }
        Button { apply(.on(today.next(.saturday, includingToday: false)), false) } label: { Label("This Weekend", systemImage: "sofa.fill") }
        Button { apply(.on(today.startOfWeek.adding(days: 7)), false) } label: { Label("Next Week", systemImage: "arrow.right.circle") }
        Button { apply(.anytime, false) } label: { Label("Anytime", systemImage: SmartList.anytime.symbol) }
        Button { apply(.someday, false) } label: { Label("Someday", systemImage: SmartList.someday.symbol) }
    }
}
