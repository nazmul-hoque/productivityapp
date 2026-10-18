import SwiftUI
import TaskCore

/// Fast capture with a live preview of what the parser understood.
struct QuickAddView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let context: QuickAddContext

    @State private var text: String
    @State private var added = 0
    @FocusState private var focused: Bool

    /// - Parameter prefill: text to start with (from a `daybook://new` link).
    init(context: QuickAddContext, prefill: String = "") {
        self.context = context
        _text = State(initialValue: prefill)
    }

    var body: some View {
        let parsed = QuickAddParser(today: store.today).parse(text)
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField("New To-Do", text: $text)
                    .font(.title3)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(add)

                if !text.isEmpty {
                    chips(for: parsed)
                }

                Text("Try “Call Sam tomorrow at 10am #phone /Work !friday”")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .navigationTitle(destinationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                        .bold()
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
            .sensoryFeedback(.success, trigger: added)
        }
    }

    private func add() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.quickAdd(text, context: context)
        added += 1
        dismiss()
    }

    private var destinationTitle: String {
        if let id = context.headingID, let heading = store.db.headings[id] { return heading.title }
        if let id = context.projectID { return store.db.projects[id]?.title ?? "New To-Do" }
        if let id = context.areaID { return store.db.areas[id]?.title ?? "New To-Do" }
        if let day = context.day { return DayLabel.short(day, today: store.today) }
        if context.evening { return "This Evening" }
        return context.list?.title ?? SmartList.inbox.title
    }

    @ViewBuilder
    private func chips(for parsed: QuickAddResult) -> some View {
        let items = chipItems(parsed)
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.text) { item in
                        Label(item.text, systemImage: item.symbol)
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(item.tint.opacity(0.15)))
                            .foregroundStyle(item.tint)
                    }
                }
            }
        }
    }

    private struct Chip {
        var text: String
        var symbol: String
        var tint: Color
    }

    private func chipItems(_ parsed: QuickAddResult) -> [Chip] {
        var items: [Chip] = []
        switch parsed.when {
        case .on(let day):
            if parsed.isEvening && day == store.today {
                items.append(Chip(text: "This Evening", symbol: "moon.fill", tint: Theme.evening))
            } else {
                items.append(Chip(text: DayLabel.short(day, today: store.today),
                                  symbol: day <= store.today ? "star.fill" : "calendar",
                                  tint: day <= store.today ? SmartList.today.tint : SmartList.upcoming.tint))
            }
        case .someday:
            items.append(Chip(text: "Someday", symbol: SmartList.someday.symbol, tint: SmartList.someday.tint))
        case .anytime:
            items.append(Chip(text: "Anytime", symbol: SmartList.anytime.symbol, tint: SmartList.anytime.tint))
        case .inbox, nil:
            break
        }
        if let reminder = parsed.reminder {
            items.append(Chip(text: reminder.formatted, symbol: "bell.fill", tint: .orange))
        }
        if let deadline = parsed.deadline {
            items.append(Chip(text: "Due " + DayLabel.short(deadline, today: store.today), symbol: "flag.fill", tint: Theme.deadline))
        }
        if let project = parsed.project {
            items.append(Chip(text: project, symbol: "circle.dashed", tint: .accentColor))
        }
        for tag in parsed.tags {
            items.append(Chip(text: tag, symbol: "tag.fill", tint: .gray))
        }
        return items
    }
}
