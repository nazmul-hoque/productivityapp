import SwiftUI
import TaskCore

struct AreaView: View {
    @Environment(AppStore.self) private var store
    let areaID: UUID
    @Binding var selection: Destination?

    @State private var renaming = false
    @State private var name = ""
    @State private var confirmingDelete = false

    var body: some View {
        let todos = store.db.looseTodos(inArea: areaID)
        let projects = store.db.openProjects(inArea: areaID)
        List {
            if !projects.isEmpty {
                Section("Projects") {
                    ForEach(projects) { project in
                        Button { selection = .project(project.id) } label: {
                            Label {
                                Text(project.title).foregroundStyle(.primary)
                            } icon: {
                                ProgressRing(progress: store.db.progress(ofProject: project.id), size: 16)
                            }
                        }
                    }
                }
            }
            Section {
                let slot = DropSection(id: "area-\(areaID)", context: QuickAddContext(areaID: areaID), order: todos.map(\.id))
                ForEach(todos) { TodoRow(todo: $0, context: .project).dropSlot(slot, row: $0.id) }
                    .onMove { store.move(in: todos, from: $0, to: $1) }
            }
        }
        .listStyle(.plain)
        .navigationTitle(store.db.areas[areaID]?.title ?? "Area")
        .overlay {
            if todos.isEmpty && projects.isEmpty {
                ContentUnavailableView("Empty area", systemImage: "square.on.square",
                                       description: Text("Add to-dos or projects here."))
            }
        }
        .toolbar {
            Menu {
                Button("Delete Area", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .confirmationDialog("Delete this area? Its projects and to-dos are kept.", isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete Area", role: .destructive) {
                selection = nil
                store.perform { $0.removeArea(areaID) }
            }
        }
    }
}
