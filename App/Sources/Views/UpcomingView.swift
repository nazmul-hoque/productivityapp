import SwiftUI
import TaskCore

struct UpcomingView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let groups = store.db.upcoming(today: store.today)
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.todos, id: \.self) { todo in
                        TodoRow(todo: todo, context: .upcoming, isPreview: isPreview(todo))
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
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Upcoming")
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView("Nothing upcoming", systemImage: SmartList.upcoming.symbol,
                                       description: Text("Scheduled to-dos and deadlines show up here."))
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
}
