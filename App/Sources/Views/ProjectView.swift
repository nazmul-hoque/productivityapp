import SwiftUI
import TaskCore

struct ProjectView: View {
    @Environment(AppStore.self) private var store
    let projectID: UUID

    @State private var showingEditor = false
    @State private var showingNewHeading = false
    @State private var newHeading = ""

    var body: some View {
        if let project = store.db.project(projectID) {
            content(project)
        } else {
            ContentUnavailableView("Project not found", systemImage: "questionmark.folder")
        }
    }

    private func content(_ project: Project) -> some View {
        let sections = store.db.sections(ofProject: projectID)
        return List {
            Section {
                HStack(spacing: 10) {
                    ProgressRing(progress: store.db.progress(ofProject: projectID), size: 22)
                    if let deadline = project.deadline {
                        Label("Deadline \(DayLabel.short(deadline, today: store.today))", systemImage: "flag.fill")
                            .font(.subheadline)
                            .foregroundStyle(deadline <= store.today ? Theme.deadline : Color.secondary)
                    }
                    if project.when == .someday {
                        Label("Someday", systemImage: SmartList.someday.symbol)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if !project.notes.isEmpty {
                    Text(project.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .listRowSeparator(.hidden)

            ForEach(sections) { section in
                let slot = DropSection(id: "project-\(projectID)-\(section.heading?.id.uuidString ?? "top")",
                                       context: QuickAddContext(projectID: projectID, headingID: section.heading?.id),
                                       order: section.todos.map(\.id))
                Section {
                    ForEach(section.todos) { TodoRow(todo: $0, context: .project).dropSlot(slot, row: $0.id) }
                        .onMove { store.move(in: section.todos, from: $0, to: $1) }
                } header: {
                    if let heading = section.heading {
                        HeadingHeader(heading: heading)
                            .dropSlot(slot, row: nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(project.title)
        .toolbar {
            Menu {
                Button { showingEditor = true } label: { Label("Edit Project", systemImage: "pencil") }
                Button { newHeading = ""; showingNewHeading = true } label: { Label("Add Heading", systemImage: "text.badge.plus") }
                Divider()
                Button { store.perform { $0.completeProject(projectID) } } label: {
                    Label("Complete Project", systemImage: "checkmark.circle")
                }
                Button(role: .destructive) { store.perform { $0.trashProject(projectID) } } label: {
                    Label("Delete Project", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .sheet(isPresented: $showingEditor) { ProjectEditorView(project: project) }
        .alert("New Heading", isPresented: $showingNewHeading) {
            TextField("Heading", text: $newHeading)
            Button("Add") {
                let title = newHeading.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { store.perform { _ = $0.addHeading(title, toProject: projectID) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct HeadingHeader: View {
    @Environment(AppStore.self) private var store
    let heading: Heading

    var body: some View {
        HStack {
            Text(heading.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .textCase(nil)
            Spacer()
            Menu {
                Button(role: .destructive) { store.perform { $0.removeHeading(heading.id) } } label: {
                    Label("Remove Heading", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ProjectEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Project
    @State private var hasDeadline: Bool

    init(project: Project) {
        _draft = State(initialValue: project)
        _hasDeadline = State(initialValue: project.deadline != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Project title", text: $draft.title)
                    .font(.title3.weight(.semibold))
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...10)

                Section {
                    Picker("When", selection: $draft.when) {
                        Text("Anytime").tag(When.anytime)
                        Text("Someday").tag(When.someday)
                        if case .on(let day) = draft.when {
                            Text(DayLabel.short(day, today: store.today)).tag(When.on(day))
                        }
                    }
                    Toggle("Deadline", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("Due", selection: dayBinding($draft.deadline, default: store.today.adding(days: 7)),
                                   displayedComponents: .date)
                    }
                    Picker("Area", selection: $draft.areaID) {
                        Text("None").tag(UUID?.none)
                        ForEach(store.db.sortedAreas) { Text($0.title).tag(UUID?.some($0.id)) }
                    }
                }
            }
            .navigationTitle("Project")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: hasDeadline) { _, on in
                if on && draft.deadline == nil { draft.deadline = store.today.adding(days: 7) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if !hasDeadline { draft.deadline = nil }
                        store.perform { $0.updateProject(draft) }
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Bridges an optional `LocalDay` to a `DatePicker`'s `Date`.
func dayBinding(_ day: Binding<LocalDay?>, default fallback: LocalDay) -> Binding<Date> {
    Binding(
        get: { (day.wrappedValue ?? fallback).date() },
        set: { day.wrappedValue = LocalDay($0) }
    )
}
