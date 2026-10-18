import SwiftUI
import TaskCore

/// Quick Find: jump to a list or project, or find a to-do.
struct SearchView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Destination?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                let lists = SmartList.allCases.filter { matches($0.title) }
                let projects = store.db.projects.values.filter { !$0.isDeleted && $0.status == .open && matches($0.title) }
                let areas = store.db.sortedAreas.filter { matches($0.title) }

                if !lists.isEmpty || !projects.isEmpty || !areas.isEmpty {
                    Section("Lists") {
                        ForEach(lists) { list in
                            jump(.list(list)) { Label(list.title, systemImage: list.symbol).foregroundStyle(.primary) }
                        }
                        ForEach(areas) { area in
                            jump(.area(area.id)) { Label(area.title, systemImage: "square.on.square").foregroundStyle(.primary) }
                        }
                        ForEach(projects.sorted { $0.title < $1.title }) { project in
                            jump(.project(project.id)) { Label(project.title, systemImage: "circle.dashed").foregroundStyle(.primary) }
                        }
                    }
                }

                let todos = store.db.search(query)
                if !todos.isEmpty {
                    Section("To-Dos") {
                        ForEach(todos) { TodoRow(todo: $0, context: .list) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Quick Find")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .overlay {
                if !query.isEmpty && store.db.search(query).isEmpty && !hasListMatches {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }

    private var hasListMatches: Bool {
        SmartList.allCases.contains { matches($0.title) }
            || store.db.projects.values.contains { !$0.isDeleted && $0.status == .open && matches($0.title) }
            || store.db.areas.values.contains { matches($0.title) }
    }

    private func matches(_ title: String) -> Bool {
        !query.isEmpty && title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func jump<Content: View>(_ destination: Destination, @ViewBuilder label: () -> Content) -> some View {
        let content = label()
        return Button {
            selection = destination
            dismiss()
        } label: {
            content
        }
    }
}
