import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A signed-in user's session with Supabase Auth.
public struct AuthSession: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var userID: UUID
    public var email: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, userID: UUID, email: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
        self.email = email
    }
}

/// Small secrets kept between launches (the Keychain in the app).
public protocol SecureStorage: Sendable {
    func data(for key: String) -> Data?
    func set(_ data: Data?, for key: String)
}

public enum AuthError: Error, Equatable, CustomStringConvertible {
    case notSignedIn
    /// The link was opened on a different device than the one that asked for it, or is malformed.
    case invalidLink
    /// Supabase allows one email per address every so often.
    case rateLimited(String)
    /// The link or code is wrong, used or expired, or the session was revoked.
    case rejected(String)
    case server(status: Int, message: String)

    public var description: String {
        switch self {
        case .notSignedIn: "You're not signed in."
        case .invalidLink: "This sign-in link can't be used here. Open it on the device where you asked for it, or enter the code from the email."
        case .rateLimited(let message): message
        case .rejected(let message): message
        case .server(_, let message): message
        }
    }
}

/// Email sign-in with Supabase Auth: a magic link (with PKCE, so only this device can use it) or
/// the 6-digit code from the same email. Keeps the session in `storage` and refreshes it.
public actor SupabaseAuth {
    private let config: SupabaseConfig
    private let session: URLSession
    private let storage: any SecureStorage
    private let now: @Sendable () -> Date
    private var refreshing: Task<AuthSession, Error>?

    static let sessionKey = "auth.session"
    static let verifierKey = "auth.pkce-verifier"
    /// Refresh this long before the access token expires.
    static let refreshMargin: TimeInterval = 60

    public private(set) var currentSession: AuthSession?

    public init(config: SupabaseConfig, storage: any SecureStorage, session: URLSession = .shared,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.storage = storage
        self.session = session
        self.now = now
        currentSession = storage.data(for: Self.sessionKey).flatMap { try? JSONDecoder().decode(AuthSession.self, from: $0) }
    }

    // MARK: - Signing in

    /// Emails a sign-in link (which opens `redirectTo`) and a code. Creates the account if new.
    public func sendMagicLink(to email: String, redirectTo: URL) async throws {
        let verifier = Self.makeVerifier()
        storage.set(Data(verifier.utf8), for: Self.verifierKey)
        struct Body: Encodable {
            var email: String
            var create_user = true
            var code_challenge: String
            var code_challenge_method = "s256"
        }
        var components = URLComponents(url: authURL("otp"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "redirect_to", value: redirectTo.absoluteString)]
        _ = try await post(components.url!, Body(email: email, code_challenge: Self.challenge(for: verifier)))
    }

    /// Whether `url` is a sign-in link coming back to the app.
    public nonisolated func isCallback(_ url: URL, redirectTo: URL) -> Bool {
        url.scheme == redirectTo.scheme && url.host == redirectTo.host && url.path == redirectTo.path
    }

    /// Completes sign-in from the link in the email.
    @discardableResult
    public func handleCallback(_ url: URL) async throws -> AuthSession {
        let parameters = Self.parameters(of: url)
        if let error = parameters["error_description"] ?? parameters["error"] {
            throw AuthError.rejected(error.replacingOccurrences(of: "+", with: " "))
        }
        guard let code = parameters["code"],
              let verifier = storage.data(for: Self.verifierKey).map({ String(decoding: $0, as: UTF8.self) })
        else { throw AuthError.invalidLink }
        struct Body: Encodable {
            var auth_code: String
            var code_verifier: String
        }
        let session = try await tokenRequest(grant: "pkce", Body(auth_code: code, code_verifier: verifier))
        storage.set(nil, for: Self.verifierKey)
        return session
    }

    /// Completes sign-in with the 6-digit code from the email.
    @discardableResult
    public func verify(email: String, code: String) async throws -> AuthSession {
        struct Body: Encodable {
            var type = "email"
            var email: String
            var token: String
        }
        let data = try await post(authURL("verify"), Body(email: email, token: code.trimmingCharacters(in: .whitespaces)))
        return try store(Self.decodeSession(data))
    }

    // MARK: - Using the session

    /// A valid access token, refreshed first if it is about to expire.
    public func accessToken() async throws -> String {
        guard let current = currentSession else { throw AuthError.notSignedIn }
        if current.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return current.accessToken }
        return try await refresh().accessToken
    }

    /// Refreshes the session; concurrent callers share one request (refresh tokens are single-use).
    @discardableResult
    public func refresh() async throws -> AuthSession {
        if let refreshing { return try await refreshing.value }
        guard let current = currentSession else { throw AuthError.notSignedIn }
        let task = Task { try await self.performRefresh(current.refreshToken) }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func performRefresh(_ refreshToken: String) async throws -> AuthSession {
        struct Body: Encodable { var refresh_token: String }
        do {
            return try await tokenRequest(grant: "refresh_token", Body(refresh_token: refreshToken))
        } catch AuthError.rejected {
            // Revoked or expired for good: sign out locally.
            clear()
            throw AuthError.notSignedIn
        }
    }

    /// Signs out here (other devices stay signed in).
    public func signOut() async {
        if let current = currentSession {
            var request = URLRequest(url: authURL("logout", query: [URLQueryItem(name: "scope", value: "local")]))
            request.httpMethod = "POST"
            request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(current.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await session.data(for: request)  // Best effort; the local session goes regardless.
        }
        clear()
    }

    // MARK: - Requests

    private func tokenRequest(grant: String, _ body: some Encodable) async throws -> AuthSession {
        let data = try await post(authURL("token", query: [URLQueryItem(name: "grant_type", value: grant)]), body)
        return try store(Self.decodeSession(data))
    }

    private func store(_ session: AuthSession) throws -> AuthSession {
        currentSession = session
        storage.set(try JSONEncoder().encode(session), for: Self.sessionKey)
        return session
    }

    private func clear() {
        currentSession = nil
        storage.set(nil, for: Self.sessionKey)
    }

    private func authURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: config.url.appendingPathComponent("auth/v1/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func post(_ url: URL, _ body: some Encodable) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.error(status: status, data: data) }
        return data
    }

    // MARK: - Parsing

    static func decodeSession(_ data: Data) throws -> AuthSession {
        struct Response: Decodable {
            struct User: Decodable {
                var id: UUID
                var email: String?
            }
            var access_token: String
            var refresh_token: String
            var expires_at: Double?
            var expires_in: Double?
            var user: User
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let expiresAt = response.expires_at.map(Date.init(timeIntervalSince1970:))
            ?? Date().addingTimeInterval(response.expires_in ?? 3600)
        return AuthSession(accessToken: response.access_token, refreshToken: response.refresh_token,
                           expiresAt: expiresAt, userID: response.user.id, email: response.user.email)
    }

    /// Supabase Auth errors come as `{"msg": …}`, `{"error_description": …}` or `{"message": …}`.
    static func error(status: Int, data: Data) -> AuthError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let message = (json["msg"] ?? json["error_description"] ?? json["message"] ?? json["error"]) as? String
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 429: return .rateLimited(message)
        case 400, 401, 403, 404, 422: return .rejected(message)
        default: return .server(status: status, message: message)
        }
    }

    /// Query and fragment parameters of a callback URL (Supabase uses either).
    static func parameters(of url: URL) -> [String: String] {
        var result: [String: String] = [:]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        for item in components?.queryItems ?? [] { result[item.name] = item.value }
        if let fragment = components?.fragment, var fragmentComponents = URLComponents(string: "x:/") {
            fragmentComponents.query = fragment
            for item in fragmentComponents.queryItems ?? [] { result[item.name] = item.value }
        }
        return result
    }

    // MARK: - PKCE

    static func makeVerifier() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
