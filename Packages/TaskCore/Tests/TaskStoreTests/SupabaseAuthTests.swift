import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import TaskCore
@testable import TaskStore

final class MemoryStorage: SecureStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func data(for key: String) -> Data? { lock.withLock { values[key] } }
    func set(_ data: Data?, for key: String) { lock.withLock { values[key] = data } }
}

final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@Suite(.serialized)
struct SupabaseAuthTests {
    static let host = "auth.test"
    let config = SupabaseConfig(url: URL(string: "https://\(host)")!, anonKey: "anon-key")
    let redirect = URL(string: "daybook://auth-callback")!
    let userID = UUID(uuidString: "0A0A0A0A-0000-0000-0000-000000000001")!
    let storage = MemoryStorage()
    let clock = Clock()

    init() {
        StubProtocol.reset(Self.host)
    }

    func makeAuth() -> SupabaseAuth {
        let clock = clock
        return SupabaseAuth(config: config, storage: storage, session: StubProtocol.session(), now: { clock.now })
    }

    func respond(_ status: Int, _ body: String) {
        StubProtocol.respond(on: Self.host, status: status, body: body)
    }

    func sessionJSON(access: String = "access-1", refresh: String = "refresh-1", expiresIn: Double = 3600) -> String {
        """
        {"access_token":"\(access)","token_type":"bearer","expires_in":\(Int(expiresIn)),
         "expires_at":\(Int(clock.now.timeIntervalSince1970 + expiresIn)),"refresh_token":"\(refresh)",
         "user":{"id":"\(userID.uuidString.lowercased())","email":"sam@example.com","aud":"authenticated"}}
        """
    }

    func body(_ recorded: StubProtocol.Recorded) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try #require(recorded.body)) as? [String: Any] ?? [:]
    }

    @Test func pkceChallengeMatchesTheRFCExample() {
        // base64url(SHA-256(verifier)) without padding, computed independently with Python's hashlib.
        #expect(SupabaseAuth.challenge(for: "dBjftJeZ4CVP-mJ92K9qXmKr5Gq8lvKJ7rDThTHgzdg") == "xj512ArJjQ7ZmQqDi05Ngx6kQ5ajluFl-8hfbDMWBWg")
        let verifier = SupabaseAuth.makeVerifier()
        #expect(verifier.count == 43)
        #expect(!verifier.contains("=") && !verifier.contains("+") && !verifier.contains("/"))
    }

    @Test func magicLinkRoundTrip() async throws {
        let auth = makeAuth()
        respond(200, "{}")
        try await auth.sendMagicLink(to: "sam@example.com", redirectTo: redirect)

        let otp = try #require(StubProtocol.requests(on: Self.host).last)
        #expect(otp.request.url?.path == "/auth/v1/otp")
        #expect(otp.request.url?.query == "redirect_to=daybook://auth-callback")
        #expect(otp.request.value(forHTTPHeaderField: "apikey") == "anon-key")
        let sent = try body(otp)
        #expect(sent["email"] as? String == "sam@example.com")
        #expect(sent["code_challenge_method"] as? String == "s256")
        let verifier = String(decoding: try #require(storage.data(for: SupabaseAuth.verifierKey)), as: UTF8.self)
        #expect(sent["code_challenge"] as? String == SupabaseAuth.challenge(for: verifier))

        // The email's link comes back to the app.
        respond(200, sessionJSON())
        let callback = URL(string: "daybook://auth-callback?code=abc-123")!
        #expect(auth.isCallback(callback, redirectTo: redirect))
        let session = try await auth.handleCallback(callback)
        #expect(session.userID == userID && session.email == "sam@example.com" && session.accessToken == "access-1")

        let exchange = try #require(StubProtocol.requests(on: Self.host).last)
        #expect(exchange.request.url?.path == "/auth/v1/token")
        #expect(exchange.request.url?.query == "grant_type=pkce")
        let exchanged = try body(exchange)
        #expect(exchanged["auth_code"] as? String == "abc-123")
        #expect(exchanged["code_verifier"] as? String == verifier)
        #expect(storage.data(for: SupabaseAuth.verifierKey) == nil)

        // The session survives a relaunch.
        #expect(await makeAuth().currentSession == session)
    }

    @Test func badCallbacks() async throws {
        let auth = makeAuth()
        // No verifier: the link was asked for on another device.
        await #expect(throws: AuthError.invalidLink) { try await auth.handleCallback(URL(string: "daybook://auth-callback?code=x")!) }
        // Supabase reports errors in the fragment.
        let expired = URL(string: "daybook://auth-callback#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired")!
        await #expect(throws: AuthError.rejected("Email link is invalid or has expired")) { try await auth.handleCallback(expired) }
        #expect(!auth.isCallback(URL(string: "daybook://today")!, redirectTo: redirect))
    }

    @Test func signInWithTheCode() async throws {
        let auth = makeAuth()
        respond(200, sessionJSON())
        let session = try await auth.verify(email: "sam@example.com", code: " 123456 ")
        #expect(session.userID == userID)
        let sent = try body(try #require(StubProtocol.requests(on: Self.host).last))
        #expect(sent["type"] as? String == "email" && sent["token"] as? String == "123456")

        respond(403, #"{"code":403,"error_code":"otp_expired","msg":"Token has expired or is invalid"}"#)
        await #expect(throws: AuthError.rejected("Token has expired or is invalid")) { try await auth.verify(email: "sam@example.com", code: "000000") }
    }

    @Test func refreshesNearExpiryOnce() async throws {
        let auth = makeAuth()
        respond(200, sessionJSON(expiresIn: 3600))
        try await auth.verify(email: "sam@example.com", code: "123456")
        #expect(try await auth.accessToken() == "access-1")  // fresh: no request

        clock.now = clock.now.addingTimeInterval(3600 - 30)  // inside the refresh margin
        respond(200, sessionJSON(access: "access-2", refresh: "refresh-2"))
        StubProtocol.reset(Self.host)
        async let a = auth.accessToken()
        async let b = auth.accessToken()
        let tokens = try await [a, b]
        #expect(tokens == ["access-2", "access-2"])
        let refreshes = StubProtocol.requests(on: Self.host)
        #expect(refreshes.count == 1)
        #expect(refreshes.first?.request.url?.query == "grant_type=refresh_token")
        #expect(try body(refreshes[0])["refresh_token"] as? String == "refresh-1")
    }

    @Test func revokedSessionSignsOut() async throws {
        let auth = makeAuth()
        respond(200, sessionJSON(expiresIn: 10))
        try await auth.verify(email: "sam@example.com", code: "123456")
        respond(400, #"{"error":"invalid_grant","error_description":"Invalid Refresh Token: Already Used"}"#)
        await #expect(throws: AuthError.notSignedIn) { try await auth.accessToken() }
        #expect(await auth.currentSession == nil)
        #expect(storage.data(for: SupabaseAuth.sessionKey) == nil)
    }

    @Test func rateLimitAndSignOut() async throws {
        let auth = makeAuth()
        respond(429, #"{"code":429,"error_code":"over_email_send_rate_limit","msg":"For security purposes, you can only request this after 52 seconds."}"#)
        await #expect(throws: AuthError.rateLimited("For security purposes, you can only request this after 52 seconds.")) {
            try await auth.sendMagicLink(to: "sam@example.com", redirectTo: redirect)
        }

        respond(200, sessionJSON())
        try await auth.verify(email: "sam@example.com", code: "123456")
        respond(204, "")
        await auth.signOut()
        #expect(await auth.currentSession == nil)
        let logout = try #require(StubProtocol.requests(on: Self.host).last)
        #expect(logout.request.url?.path == "/auth/v1/logout")
        #expect(logout.request.value(forHTTPHeaderField: "Authorization") == "Bearer access-1")
        await #expect(throws: AuthError.notSignedIn) { try await auth.accessToken() }
    }
}

@Suite(.serialized)
struct AccountAdoptionTests {
    let today = LocalDay(iso: "2026-10-14")!

    @Test func keepingLocalDataUploadsItToTheNewAccount() async throws {
        let server = FakeServer()
        let device = try Device(server: server)
        try device.edit { $0.add(Todo(title: "Mine"), today: today) }
        try await device.sync()
        #expect(try await device.store.hasLocalData())

        // Signed in to a different account: start over with it, keeping what's here.
        let otherServer = FakeServer()
        try await device.store.adoptAccount(UUID(), keepingLocalData: true)
        let moved = SyncEngine(store: device.store, transport: otherServer)
        let result = try await moved.sync()
        #expect(result.pushed == 1)
        #expect(try await otherServer.pull(since: 0, limit: 10).records.count == 1)
    }

    @Test func replacingLocalDataMirrorsTheAccount() async throws {
        let server = FakeServer()
        let phone = try Device(server: server)
        try phone.edit { $0.add(Todo(title: "In the account"), today: today) }
        try await phone.sync()

        let tablet = try Device(server: server)
        try tablet.edit { $0.add(Todo(title: "Sample to-do"), today: today) }
        let account = UUID()
        try await tablet.store.adoptAccount(account, keepingLocalData: false)
        #expect(try await tablet.store.syncAccount() == account)
        #expect(try await !tablet.store.hasLocalData())
        try await tablet.sync()
        #expect(try tablet.db.todos.values.map(\.title) == ["In the account"])
        #expect(try await server.pull(since: 0, limit: 10).records.count == 1)  // the sample never uploaded
    }

    @Test func detachingKeepsLocalDataAndRequeuesIt() async throws {
        let server = FakeServer()
        let device = try Device(server: server)
        try device.edit { $0.add(Todo(title: "Keep me"), today: today) }
        let account = UUID()
        try await device.store.adoptAccount(account, keepingLocalData: true)
        try await device.sync()
        #expect(try await device.store.pendingChanges().records.isEmpty)

        // The account was deleted: forget it, keep the to-do, and be ready to upload it anew.
        try await device.store.detachFromAccount()
        #expect(try await device.store.syncAccount() == nil)
        #expect(try device.db.todos.values.map(\.title) == ["Keep me"])
        #expect(try await device.store.pendingChanges().records.count == 1)
        #expect(try await device.store.syncCursor() == 0)
    }
}
