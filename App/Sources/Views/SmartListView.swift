import SwiftUI
import TaskCore

/// Inbox, Anytime, Someday, Logbook and Trash.
struct SmartListView: View {
    @Environment(AppStore.self) private var store
    let list: SmartList
    @State private var confirmingEmptyTrash = false

    var body: some View {
        let todos = store.db.todos(in: list, today: store.today)
        let moveAction: ((IndexSet, Int) -> Void)? = isReorderable ? { store.move(in: todos, from: $0, to: $1) } : nil
        List {
            ForEach(todos) { TodoRow(todo: $0, context: rowContext) }
                .onMove(perform: moveAction)
        }
        .listStyle(.plain)
        .navigationTitle(list.title)
        .overlay {
            if todos.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: list.symbol)
            }
        }
        .toolbar {
            if list == .trash && !todos.isEmpty {
                Button("Empty Trash", role: .destructive) { confirmingEmptyTrash = true }
            }
        }
        .confirmationDialog("Permanently delete everything in the Trash?", isPresented: $confirmingEmptyTrash,
                            titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { store.perform { $0.purgeTrash(olderThan: 0) } }
        }
        .animation(.default, value: todos.map(\.id))
    }

    private var rowContext: RowContext {
        switch list {
        case .logbook: .logbook
        case .trash: .trash
        default: .list
        }
    }

    private var isReorderable: Bool {
        [.inbox, .anytime, .someday].contains(list)
    }

    private var emptyTitle: String {
        switch list {
        case .inbox: "Inbox zero"
        case .logbook: "Nothing completed yet"
        case .trash: "Trash is empty"
        default: "No to-dos"
        }
    }
}
