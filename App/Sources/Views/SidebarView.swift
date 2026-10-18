import SwiftUI
import TaskCore

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: Destination?
    @Binding var showingSearch: Bool

    @State private var newListKind: NewListKind?
    @State private var newListName = ""

    enum NewListKind: Identifiable {
        case project, area
        var id: Self { self }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                row(.inbox, count: store.db.todos(in: .inbox, today: store.today).count)
            }
            Section {
                row(.today, count: store.db.todos(in: .today, today: store.today).count)
                row(.upcoming)
                row(.anytime)
                row(.someday)
            }
            Section {
                row(.logbook)
                row(.trash)
            }

            let looseProjects = store.db.openProjects(inArea: nil)
            if !looseProjects.isEmpty {
                Section {
                    ForEach(looseProjects) { projectRow($0) }
                }
            }

            ForEach(store.db.sortedAreas) { area in
                Section {
                    NavigationLink(value: Destination.area(area.id)) {
                        Label(area.title, systemImage: "square.on.square")
                            .font(.headline)
                    }
                    ForEach(store.db.openProjects(inArea: area.id)) { projectRow($0) }
                }
            }
        }
        .navigationTitle("Lists")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSearch = true } label: { Label("Quick Find", systemImage: "magnifyingglass") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button { newListName = ""; newListKind = .project } label: { Label("New Project", systemImage: "circle.dashed") }
                    Button { newListName = ""; newListKind = .area } label: { Label("New Area", systemImage: "square.on.square") }
                } label: {
                    Label("New List", systemImage: "folder.badge.plus")
                }
            }
        }
        .alert(newListKind == .area ? "New Area" : "New Project", isPresented: Binding(
            get: { newListKind != nil },
            set: { if !$0 { newListKind = nil } }
        )) {
            TextField("Name", text: $newListName)
            Button("Create") { createList() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func row(_ list: SmartList, count: Int = 0) -> some View {
        NavigationLink(value: Destination.list(list)) {
            Label {
                Text(list.title)
            } icon: {
                Image(systemName: list.symbol).foregroundStyle(list.tint)
            }
        }
        .badge(count)
    }

    private func projectRow(_ project: Project) -> some View {
        NavigationLink(value: Destination.project(project.id)) {
            Label {
                Text(project.title)
            } icon: {
                ProgressRing(progress: store.db.progress(ofProject: project.id), size: 16)
            }
        }
    }

    private func createList() {
        let name = newListName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let kind = newListKind else { return }
        switch kind {
        case .project:
            var created: Project?
            store.perform { created = $0.addProject(Project(title: name)) }
            if let created { selection = .project(created.id) }
        case .area:
            var created: Area?
            store.perform { created = $0.addArea(name) }
            if let created { selection = .area(created.id) }
        }
        newListKind = nil
    }
}
