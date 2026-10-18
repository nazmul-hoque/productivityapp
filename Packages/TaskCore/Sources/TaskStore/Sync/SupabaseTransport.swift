import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the Supabase project is. The anon key is public by design (it only identifies the
/// project; row-level security protects the data). Never put the service-role key in the app.
public struct SupabaseConfig: Sendable, Equatable {
    public var url: URL
    public var anonKey: String
    /// The REST API's base, `<url>/rest/v1` on Supabase.
    public var restURL: URL

    /// - Parameter restURL: only for pointing at a bare PostgREST server in tests.
    public init(url: URL, anonKey: String, restURL: URL? = nil) {
        self.url = url
        self.anonKey = anonKey
        self.restURL = restURL ?? url.appendingPathComponent("rest/v1")
    }
}

public enum SyncTransportError: Error, Equatable, CustomStringConvertible {
    /// The session expired or was revoked; sign in again.
    case unauthorized
    case server(status: Int, message: String)

    public var description: String {
        switch self {
        case .unauthorized: "Not signed in"
        case .server(let status, let message): "Server error \(status): \(message)"
        }
    }
}

/// Calls the `sync_push` and `sync_pull` database functions through Supabase's REST API.
public struct SupabaseTransport: SyncTransport {
    public typealias AccessToken = @Sendable () async throws -> String

    private let config: SupabaseConfig
    private let accessToken: AccessToken
    private let session: URLSession

    /// - Parameter accessToken: the signed-in user's current access token (refreshed as needed).
    public init(config: SupabaseConfig, session: URLSession = .shared, accessToken: @escaping AccessToken) {
        self.config = config
        self.session = session
        self.accessToken = accessToken
    }

    public func push(_ records: [SyncRecord]) async throws {
        struct Body: Encodable { var records: [SyncRecord] }
        _ = try await call("sync_push", body: Body(records: records))
    }

    public func pull(since cursor: Int64, limit: Int) async throws -> SyncPage {
        struct Body: Encodable {
            var since: Int64
            var max_records: Int
        }
        struct Row: Decodable {
            var entity: Entity
            var id: UUID
            var fields: [String: JSONValue]
            var clocks: [String: String]
            var deleted: Bool
            var version: Int64
        }
        let data = try await call("sync_pull", body: Body(since: cursor, max_records: limit))
        let rows = try JSONDecoder().decode([Row].self, from: data)
        return SyncPage(
            records: rows.map { SyncRecord(entity: $0.entity, id: $0.id, fields: $0.fields, clocks: $0.clocks, deleted: $0.deleted) },
            cursor: rows.last?.version ?? cursor)
    }

    private func call(_ function: String, body: some Encodable) async throws -> Data {
        var request = URLRequest(url: config.restURL.appendingPathComponent("rpc/\(function)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: return data
        case 401, 403: throw SyncTransportError.unauthorized
        default: throw SyncTransportError.server(status: status, message: String(decoding: data, as: UTF8.self))
        }
    }
}
