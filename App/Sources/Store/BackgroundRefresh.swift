import BackgroundTasks
import Foundation

/// Asks iOS to wake the app now and then to sync, so a device that hasn't been opened in a while
/// is current when it is, and gets reminders for to-dos added elsewhere.
///
/// iOS decides when (and whether) to run it, based on how often the app is used; this only sets
/// the earliest time. It never runs in the Simulator unless triggered from the debugger:
/// `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.nazmulhoque.daybook.sync"]`
enum BackgroundRefresh {
    /// Also listed under `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let identifier = "com.nazmulhoque.daybook.sync"

    /// Requests the next refresh, replacing any pending request.
    static func schedule(after interval: TimeInterval = 30 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Expected in the Simulator and when Background App Refresh is off.
            print("Background refresh not scheduled: \(error)")
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
