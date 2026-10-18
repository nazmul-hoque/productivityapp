import SwiftUI
import TaskCore

@main
struct ProductivityApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { await store.requestNotificationPermission() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        // Roll Today over at midnight and keep the trash tidy.
                        store.refresh()
                    case .background:
                        // Don't wait for the save delay; the app may be suspended.
                        Task { await store.save() }
                    default:
                        break
                    }
                }
        }
    }
}
