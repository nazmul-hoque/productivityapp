import SwiftUI
import TaskCore

/// A few pages shown on first launch. The "Get to know the app" project goes into the details.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Page {
        var symbol: String
        var tint: Color
        var title: String
        var body: String
    }

    private let pages = [
        Page(symbol: "checkmark.square.fill", tint: .accentColor, title: "Welcome",
             body: "A calm place for everything you need to do, so your head can stay clear."),
        Page(symbol: "star.fill", tint: SmartList.today.tint, title: "Plan your day",
             body: "Today holds what you'll work on now, with This Evening for later. Upcoming shows what's scheduled ahead, and a deadline stays separate from when you plan to start."),
        Page(symbol: "plus.circle.fill", tint: .accentColor, title: "Capture in seconds",
             body: "Tap + and type naturally: “Call Sam tomorrow at 10am #phone”. Drag + onto a list to drop a to-do exactly where it belongs."),
        Page(symbol: "square.grid.2x2.fill", tint: Theme.evening, title: "Always at hand",
             body: "Check off to-dos from the Home and Lock Screen widgets, save links from the share sheet, and snooze reminders right from the notification.\n\nThe “Get to know the app” project has more tips."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { dismiss() }
                    .opacity(page < pages.count - 1 ? 1 : 0)
                    .accessibilityHidden(page == pages.count - 1)
            }
            .padding()

            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    pageView(pages[index]).tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    dismiss()
                }
            } label: {
                Text(page < pages.count - 1 ? "Continue" : "Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .sensoryFeedback(.selection, trigger: page)
        }
        .interactiveDismissDisabled()
    }

    private func pageView(_ page: Page) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: page.symbol)
                    .font(.system(size: 72))
                    .foregroundStyle(page.tint)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                    .padding(.top, 48)
                Text(page.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(page.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
    }
}
