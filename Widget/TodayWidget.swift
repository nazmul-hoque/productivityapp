import SwiftUI
import TaskCore
import TaskStore
import WidgetKit

/// Today's to-dos, read from the shared database. Tapping it opens Today in the app.
struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
                .widgetURL(SharedStore.todayURL)
        }
        .configurationDisplayName("Today")
        .description("What's planned for today.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TodayEntry: TimelineEntry {
    struct Item: Identifiable {
        var id: UUID
        var title: String
        /// The project or area, if any.
        var container: String?
    }

    var date: Date
    var today: [Item]
    var evening: [Item]
    /// The database could not be read (the app hasn't run yet, or no App Group).
    var isUnavailable = false

    var count: Int { today.count + evening.count }

    static let sample = TodayEntry(date: Date(), today: [
        Item(id: UUID(), title: "Plan the week"),
        Item(id: UUID(), title: "Call Sam", container: "Work"),
        Item(id: UUID(), title: "Book dentist"),
    ], evening: [
        Item(id: UUID(), title: "Pick up groceries", container: "Personal"),
    ])
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(context.isPreview ? .sample : load(at: Date()))
    }

    /// The app reloads the widget after each save; otherwise it refreshes when the day changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        completion(Timeline(entries: [load(at: now)], policy: .after(tomorrow)))
    }

    private func load(at date: Date) -> TodayEntry {
        guard let url = SharedStore.databaseURL, let db = try? SQLiteStore(readingFrom: url).load() else {
            return TodayEntry(date: date, today: [], evening: [], isUnavailable: true)
        }
        let sections = db.todaySections(today: LocalDay(date))
        func item(_ todo: Todo) -> TodayEntry.Item {
            let container = todo.projectID.flatMap { db.projects[$0]?.title } ?? todo.areaID.flatMap { db.areas[$0]?.title }
            return TodayEntry.Item(id: todo.id, title: todo.title.isEmpty ? "New To-Do" : todo.title, container: container)
        }
        return TodayEntry(date: date, today: sections.today.map(item), evening: sections.evening.map(item))
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            header
            if entry.isUnavailable {
                message("Open the app to see Today.")
            } else if entry.count == 0 {
                message("All clear for today.")
            } else {
                rows
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .foregroundStyle(.yellow)
            Text("Today")
                .font(.headline)
            Spacer()
            if entry.count > 0 {
                Text("\(entry.count)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    /// How many rows fit; the rest is summarised as "+ n more".
    private var capacity: Int {
        switch family {
        case .systemSmall: 3
        case .systemMedium: 4
        default: 10
        }
    }

    @ViewBuilder
    private var rows: some View {
        let today = Array(entry.today.prefix(capacity))
        let evening = Array(entry.evening.prefix(max(0, capacity - today.count)))
        ForEach(today) { row($0) }
        // The large widget shows This Evening as its own section; smaller ones mark rows with a moon.
        if !evening.isEmpty && family == .systemLarge {
            Label("This Evening", systemImage: "moon.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.indigo)
                .padding(.top, 4)
        }
        ForEach(evening) { row($0, evening: family != .systemLarge) }
        let hidden = entry.count - today.count - evening.count
        if hidden > 0 {
            Text("+ \(hidden) more")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ item: TodayEntry.Item, evening: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: evening ? "moon" : "circle")
                .font(.caption)
                .foregroundStyle(evening ? Color.indigo : Color.secondary)
            Text(item.title)
                .font(family == .systemSmall ? .caption : .subheadline)
                .lineLimit(1)
            if let container = item.container, family != .systemSmall {
                Spacer(minLength: 4)
                Text(container)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

#Preview(as: .systemMedium) {
    TodayWidget()
} timeline: {
    TodayEntry.sample
    TodayEntry(date: Date(), today: [], evening: [])
}
