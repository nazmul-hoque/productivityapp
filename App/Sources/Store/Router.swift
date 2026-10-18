import Foundation
import Observation
import TaskCore

/// Where `daybook://` links, intents, Spotlight and controls ask the app to go. `RootView`
/// follows `pending` and clears it.
@MainActor
@Observable
final class Router {
    static let shared = Router()

    var pending: DaybookLink?

    func open(_ link: DaybookLink) {
        pending = link
    }

    /// Opens a URL if it's a Daybook link. Returns false otherwise.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let link = DaybookLink(url) else { return false }
        pending = link
        return true
    }

    /// Follows a link left by an extension (see `PendingLink`).
    func takePending() {
        if let url = PendingLink.take() { open(url) }
    }
}
