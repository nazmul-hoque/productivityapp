import SwiftUI
import TaskCore

@main
struct ProductivityApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @Environment(\.scenePhase) private var scenePhase

    private var store: AppStore { appDelegate.store }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { await store.syncReminders() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Task {
                            // The widget may have completed to-dos meanwhile.
                            await store.reloadFromDisk()
                            // Roll Today over at midnight and keep the trash tidy.
                            store.refresh()
                        }
                    case .background:
                        // Don't wait for the save delay; the app may be suspended.
                        store.saveBeforeSuspending()
                    default:
                        break
                    }
                }
        }
    }
}
