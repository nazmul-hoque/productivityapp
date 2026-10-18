import SwiftUI
import TaskCore

struct TodayView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let sections = store.db.todaySections(today: store.today)
        let todaySlot = DropSection(id: "today", context: QuickAddContext(list: .today),
                                    order: sections.today.map(\.id), inToday: true)
        let eveningSlot = DropSection(id: "evening", context: QuickAddContext(list: .today, evening: true),
                                      order: sections.evening.map(\.id), inToday: true)
        List {
            Section {
                ForEach(sections.today) { TodoRow(todo: $0, context: .today).dropSlot(todaySlot, row: $0.id) }
                    .onMove { store.move(in: sections.today, from: $0, to: $1, inToday: true) }
            }
            if !sections.evening.isEmpty {
                Section {
                    ForEach(sections.evening) { TodoRow(todo: $0, context: .today).dropSlot(eveningSlot, row: $0.id) }
                        .onMove { store.move(in: sections.evening, from: $0, to: $1, inToday: true) }
                } header: {
                    Label("This Evening", systemImage: "moon.fill")
                        .foregroundStyle(Theme.evening)
                        .font(.subheadline.weight(.semibold))
                        .dropSlot(eveningSlot, row: nil)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Today")
        .overlay {
            if sections.today.isEmpty && sections.evening.isEmpty {
                ContentUnavailableView("All clear", systemImage: SmartList.today.symbol,
                                       description: Text("Nothing planned for today."))
            }
        }
        .animation(.default, value: sections.today.map(\.id) + sections.evening.map(\.id))
    }
}
