import SwiftUI
import TaskCore

struct UpcomingView: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: Destination?

    var body: some View {
        let groups = store.db.upcoming(today: store.today)
        List {
            ForEach(groups) { group in
                // Upcoming is ordered by day, so a drop picks the day and the to-do joins its end.
                let slot = DropSection(id: "upcoming-\(group.day)", context: QuickAddContext(list: .upcoming, day: group.day), order: nil)
                Section {
                    ForEach(group.projects, id: \.self) { project in
                        UpcomingProjectRow(project: project, isPreview: isPreview(project)) {
                            selection = .project(project.id)
                        }
                        .dropSlot(slot, row: project.id)
                    }
                    ForEach(group.todos, id: \.self) { todo in
                        TodoRow(todo: todo, context: .upcoming, isPreview: isPreview(todo))
                            .dropSlot(slot, row: todo.id)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(group.day.day)")
                            .font(.title2.bold())
                            .foregroundStyle(.primary)
                        Text(header(for: group.day))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(store.today.days(until: group.day) == 1 ? "Tomorrow" : DayLabel.spoken(group.day))
                    .accessibilityAddTraits(.isHeader)
                    .dropSlot(slot, row: nil)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Upcoming")
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("Nothing upcoming", systemImage: SmartList.upcoming.symbol,
                                       description: Text("Scheduled to-dos, projects and deadlines show up here."))
            }
        }
    }

    private func header(for day: LocalDay) -> String {
        let delta = store.today.days(until: day)
        return delta == 1 ? "Tomorrow" : DayLabel.long(day)
    }

    /// Repeat previews share the real to-do's id but not its start day.
    private func isPreview(_ todo: Todo) -> Bool {
        store.db.todos[todo.id]?.when != todo.when
    }

    private func isPreview(_ project: Project) -> Bool {
        store.db.projects[project.id]?.when != project.when
    }
}

/// A project starting (or due) on an Upcoming day. Previews of later repeats are dimmed and
/// can't be opened, since they don't exist yet.
private struct UpcomingProjectRow: View {
    @Environment(AppStore.self) private var store
    let project: Project
    var isPreview = false
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ProgressRing(progress: isPreview ? 0 : store.db.progress(ofProject: project.id), size: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if !details.isEmpty {
                        Text(details.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPreview)
        .opacity(isPreview ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var details: [String] {
        var parts: [String] = []
        if let area = project.areaID.flatMap({ store.db.areas[$0] }) { parts.append(area.title) }
        if let deadline = project.deadline { parts.append("Due " + DayLabel.short(deadline, today: store.today)) }
        if project.repetition != nil { parts.append("↻") }
        return parts
    }

    private var accessibilityText: String {
        var text = "Project, \(project.title)"
        if let deadline = project.deadline { text += ", due \(DayLabel.spoken(deadline))" }
        if project.repetition != nil { text += ", repeating" }
        if isPreview { text += ", upcoming repeat" }
        return text
    }
}
