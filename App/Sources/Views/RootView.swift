import SwiftUI
import TaskCore

enum Destination: Hashable {
    case list(SmartList)
    case project(UUID)
    case area(UUID)
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: Destination?
    @State private var showingQuickAdd = false
    @State private var showingSearch = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection, showingSearch: $showingSearch)
        } detail: {
            NavigationStack {
                detail
            }
        }
        .overlay(alignment: .bottomTrailing) {
            AddButton { showingQuickAdd = true }
                .padding(.trailing, 20)
                .padding(.bottom, 24)
        }
        .sheet(isPresented: $showingQuickAdd) {
            QuickAddView(context: quickAddContext)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showingSearch) {
            SearchView(selection: $selection)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .list(.today): TodayView()
        case .list(.upcoming): UpcomingView()
        case .list(let list): SmartListView(list: list)
        case .project(let id): ProjectView(projectID: id)
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
