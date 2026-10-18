import Foundation
import Observation
import TaskCore
import TaskStore

/// Signing in and keeping this device in sync with the account.
///
/// Syncs on launch, when the app comes to the foreground, a couple of seconds after local edits,
/// and on request. Each sync saves pending edits first and reloads the app's data if the merge
/// changed anything.
@MainActor
@Observable
final class SyncController {
    enum Account: Equatable {
        /// This build has no Supabase project configured.
        case unavailable
        case signedOut
        /// A sign-in email was sent; waiting for its link or code.
        case awaitingLink(email: String)
        case signedIn(email: String?)
    }

    enum Status: Equatable {
        case idle
        case syncing
        case synced(Date)
        case failed(String)
    }

    /// Signed in to an account while this device already had to-dos and so does the account:
    /// the person chooses whether to merge them or replace this device's.
    struct PendingChoice: Identifiable, Equatable {
        var id: UUID { account }
        var account: UUID
    }

    private(set) var account: Account
    private(set) var status: Status = .idle
    private(set) var pendingChoice: PendingChoice?
    /// The last sign-in problem, shown on the account screen.
    var signInError: String?

    @ObservationIgnored private let store: AppStore
    @ObservationIgnored private let auth: SupabaseAuth?
    @ObservationIgnored private let transport: SupabaseTransport?
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var syncAgain = false

    init(store: AppStore, config: SupabaseConfig? = AppConfig.supabase) {
        self.store = store
        guard let config, let database = store.database else {
            auth = nil
            transport = nil
            account = .unavailable
            return
        }
        let auth = SupabaseAuth(config: config, storage: KeychainStorage())
        let transport = SupabaseTransport(config: config) { try await auth.accessToken() }
        self.auth = auth
        self.transport = transport
        engine = SyncEngine(store: database, transport: transport)
        account = .signedOut
        store.onSaved = { [weak self] in self?.syncSoon(after: .seconds(2)) }

        Task {
            if let session = await auth.currentSession {
                account = .signedIn(email: session.email)
                syncSoon()
            }
        }
    }

    // MARK: - Signing in

    func sendLink(to email: String) async {
        guard let auth else { return }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        signInError = nil
        do {
            try await auth.sendMagicLink(to: email, redirectTo: AppConfig.authRedirect)
            account = .awaitingLink(email: email)
        } catch {
            signInError = message(for: error)
        }
    }

    func verify(code: String) async {
        guard let auth, case .awaitingLink(let email) = account else { return }
        signInError = nil
        do {
            await didSignIn(try await auth.verify(email: email, code: code))
        } catch {
            signInError = message(for: error)
        }
    }

    /// Back to entering an email (a typo, or a different address).
    func startOver() {
        signInError = nil
        account = .signedOut
    }

    /// Handles a sign-in link opened from the email. Returns false for other URLs.
    func handle(_ url: URL) -> Bool {
        guard let auth, auth.isCallback(url, redirectTo: AppConfig.authRedirect) else { return false }
        Task {
            signInError = nil
            do {
                await didSignIn(try await auth.handleCallback(url))
            } catch {
                signInError = message(for: error)
            }
        }
        return true
    }

    private func didSignIn(_ session: AuthSession) async {
        account = .signedIn(email: session.email)
        guard let database = store.database, let transport else { return }
        do {
            await store.save()
            if try await database.syncAccount() == session.userID {
                syncSoon()
                return
            }
            // A new account for this device: if both sides have data, ask before mixing them.
            let accountHasData = try await !transport.pull(since: 0, limit: 1).records.isEmpty
            if try await database.hasLocalData(), accountHasData {
                pendingChoice = PendingChoice(account: session.userID)
            } else {
                try await database.adoptAccount(session.userID, keepingLocalData: true)
                syncSoon()
            }
        } catch {
            status = .failed(message(for: error))
        }
    }

    /// The answer to `pendingChoice`: merge this device's to-dos into the account, or replace them.
    func choose(merging: Bool) {
        guard let choice = pendingChoice else { return }
        pendingChoice = nil
        Task { await adopt(choice.account, merging: merging) }
    }

    private func adopt(_ account: UUID, merging: Bool) async {
        guard let database = store.database else { return }
        do {
            await store.save()
            try await database.adoptAccount(account, keepingLocalData: merging)
            await store.reloadFromDisk()
            await syncNow()
        } catch {
            status = .failed(message(for: error))
        }
    }

    /// Declining the choice: stay signed out, keep this device's to-dos as they are.
    func cancelSignIn() {
        pendingChoice = nil
        Task { await signOut() }
    }

    /// Signs out on this device. Its to-dos stay here; they stop syncing.
    func signOut() async {
        scheduled?.cancel()
        await auth?.signOut()
        account = auth == nil ? .unavailable : .signedOut
        status = .idle
    }

    // MARK: - Syncing

    /// Syncs after `delay`, replacing any sync already waiting (so a burst of edits syncs once).
    func syncSoon(after delay: Duration = .zero) {
        guard case .signedIn = account, pendingChoice == nil else { return }
        scheduled?.cancel()
        scheduled = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    /// Syncs now. A request while a sync runs makes it run once more when done.
    func syncNow() async {
        guard case .signedIn = account, pendingChoice == nil, let engine else { return }
        if let running {
            syncAgain = true
            await running.value
            return
        }
        let task = Task {
            repeat {
                syncAgain = false
                await runOnce(engine)
            } while syncAgain
        }
        running = task
        await task.value
        running = nil
    }

    private func runOnce(_ engine: SyncEngine) async {
        status = .syncing
        do {
            await store.save()
            let result = try await retryingOnceIfUnauthorized { try await engine.sync() }
            if result.changedLocally { await store.reloadFromDisk() }
            status = .synced(Date())
        } catch AuthError.notSignedIn {
            account = .signedOut
            status = .failed("You were signed out. Sign in again to keep syncing.")
        } catch {
            status = .failed(message(for: error))
        }
    }

    /// The server may reject a token that looked valid (revoked, clock skew): refresh once and retry.
    private func retryingOnceIfUnauthorized<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch SyncTransportError.unauthorized {
            try await auth?.refresh()
            return try await operation()
        }
    }

    private func message(for error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost:
                return "You're offline. Changes are saved here and will sync when you're back online."
            default:
                return error.localizedDescription
            }
        }
        return String(describing: error)
    }
}
