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
                    // Roll Today over at midnight and keep the trash tidy.
                    if phase == .active { store.refresh() }
                }
        }
    }
}
