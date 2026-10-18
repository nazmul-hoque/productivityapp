import SwiftUI
import TaskCore

enum Destination: Hashable {
    case list(SmartList)
    case project(UUID)
    case area(UUID)
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(SyncController.self) private var sync
    @State private var selection: Destination?
    @State private var showingQuickAdd = false
    @State private var showingSearch = false
    /// Pass `-hasSeenOnboarding YES` as a launch argument to skip it (the run skill does).
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var targets = InsertionTargets()
    @State private var dropTarget: DropTarget?
    /// Set when the add button was dropped onto a list; otherwise quick add uses the current screen.
    @State private var droppedContext: QuickAddContext?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, showingSearch: $showingSearch)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .environment(\.insertionTargets, targets)
        .onAppear {
            // Rows move under a still finger while the list auto-scrolls; keep the line on them.
            targets.autoScroller.onScroll = { [targets] point in
                dropTarget = targets.target(at: point)
            }
        }
        .overlay { insertionLine }
        .overlay(alignment: .bottomTrailing) {
            AddButton {
                showingQuickAdd = true
            } onDrag: { point in
                dropTarget = point.flatMap(targets.target(at:))
                targets.autoScroller.update(point)
            } onDrop: { point in
                // Dropped away from any list: same as a tap.
                droppedContext = targets.target(at: point)?.context
                showingQuickAdd = true
            }
            .padding(.trailing, 20)
            .padding(.bottom, 24)
        }
        .sensoryFeedback(.selection, trigger: dropTarget?.context)
        .sheet(isPresented: $showingQuickAdd, onDismiss: { droppedContext = nil }) {
            QuickAddView(context: droppedContext ?? quickAddContext)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingSearch) {
            SearchView(selection: $selection)
        }
        .fullScreenCover(isPresented: Binding(get: { !hasSeenOnboarding }, set: { hasSeenOnboarding = !$0 })) {
            OnboardingView()
        }
        .onOpenURL { url in
            if sync.handle(url) { return }
            if url == SharedStore.todayURL { selection = .list(.today) }
        }
        // Stays up until a button is chosen; the buttons clear `pendingChoice`.
        .confirmationDialog("This iPhone already has to-dos", isPresented: Binding(
            get: { sync.pendingChoice != nil }, set: { _ in }
        ), titleVisibility: .visible) {
            Button("Merge Them") { sync.choose(merging: true) }
            Button("Use the Account's To-Dos", role: .destructive) { sync.choose(merging: false) }
            Button("Cancel", role: .cancel) { sync.cancelSignIn() }
        } message: {
            Text("Your account has to-dos too. Merge this iPhone's into the account, or replace them with the account's?")
        }
    }

    /// Shows where a dragged add button would insert the new to-do.
    private var insertionLine: some View {
        GeometryReader { proxy in
            if let target = dropTarget {
                let origin = proxy.frame(in: .global).origin
                HStack(spacing: 0) {
                    Circle().stroke(Color.accentColor, lineWidth: 2).frame(width: 8, height: 8)
                    Rectangle().fill(Color.accentColor).frame(height: 2)
                }
                .frame(width: target.maxX - target.minX - 16)
                .position(x: (target.minX + target.maxX) / 2 - origin.x, y: target.y - origin.y)
                .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: target.y)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .list(.today): TodayView()
        case .list(.upcoming): UpcomingView(selection: $selection)
        case .list(let list): SmartListView(list: list)
        case .project(let id): ProjectView(projectID: id, selection: $selection)
        case .area(let id): AreaView(areaID: id, selection: $selection)
        case nil:
            ContentUnavailableView("Pick a list", systemImage: "checklist", description: Text("Choose a list from the sidebar."))
        }
    }

    private var quickAddContext: QuickAddContext {
        switch selection {
        case .list(let list): QuickAddContext(list: list)
        case .project(let id): QuickAddContext(projectID: id)
        case .area(let id): QuickAddContext(areaID: id)
        case nil: QuickAddContext()
        }
    }
}
