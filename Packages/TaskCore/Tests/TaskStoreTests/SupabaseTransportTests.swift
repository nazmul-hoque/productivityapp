import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TaskStore

/// Answers requests with canned responses per host, and records them. Each suite uses its own
/// host, so suites running in parallel don't see each other's requests.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded {
        var request: URLRequest
        var body: Data?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) private static var recorded: [String: [Recorded]] = [:]

    static func respond(on host: String, status: Int, body: String) {
        lock.withLock { responses[host] = (status, body) }
    }

    static func requests(on host: String) -> [Recorded] {
        lock.withLock { recorded[host] ?? [] }
    }

    static func reset(_ host: String) {
        lock.withLock { recorded[host] = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let canned = Self.lock.withLock {
            Self.recorded[host, default: []].append(Recorded(request: request, body: body))
            return Self.responses[host] ?? (500, "no stub")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: canned.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(canned.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite(.serialized)
struct SupabaseTransportTests {
    static let host = "transport.test"
    let transport = SupabaseTransport(config: SupabaseConfig(url: URL(string: "https://\(host)")!, anonKey: "anon-key"),
                                      session: StubProtocol.session(), accessToken: { "user-token" })

    func respond(_ status: Int, _ body: String) {
        StubProtocol.respond(on: Self.host, status: status, body: body)
    }

    var last: StubProtocol.Recorded? { StubProtocol.requests(on: Self.host).last }

    @Test func pushCallsTheFunctionWithRecords() async throws {
        respond(204, "")
        let id = UUID()
        try await transport.push([SyncRecord(entity: .todo, id: id, fields: ["title": .string("Hi")], clocks: ["title": "c1"])])

        let request = try #require(last?.request)
        #expect(request.url?.absoluteString == "https://transport.test/rest/v1/rpc/sync_push")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon-key")
        #expect(request.value(forHTTPHeaderField: "Content-Profile") == "daybook")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer user-token")
        let body = try JSONDecoder().decode([String: [SyncRecord]].self, from: try #require(last?.body))
        #expect(body["records"]?.first?.id == id)
        #expect(body["records"]?.first?.fields["title"] == .string("Hi"))
    }

    @Test func pullDecodesRowsAndAdvancesTheCursor() async throws {
        respond(200, """
            [{"entity":"todo","id":"11111111-1111-1111-1111-111111111111","fields":{"title":"A","done":true,"n":2},
              "clocks":{"title":"c"},"deleted":false,"version":41},
             {"entity":"area","id":"22222222-2222-2222-2222-222222222222","fields":{},"clocks":{"_deleted":"d"},
              "deleted":true,"version":42}]
            """)
        let page = try await transport.pull(since: 40, limit: 2)
        #expect(page.cursor == 42)
        #expect(page.records.map(\.entity) == [.todo, .area])
        #expect(page.records[0].fields == ["title": .string("A"), "done": .bool(true), "n": .number(2)])
        #expect(page.records[1].deleted)
        let body = try JSONSerialization.jsonObject(with: try #require(last?.body)) as? [String: Int]
        #expect(body == ["since": 40, "max_records": 2])
    }

    @Test func emptyPullKeepsTheCursor() async throws {
        respond(200, "[]")
        #expect(try await transport.pull(since: 7, limit: 500).cursor == 7)
    }

    @Test func errorsAreReported() async throws {
        respond(401, #"{"message":"JWT expired"}"#)
        await #expect(throws: SyncTransportError.unauthorized) { try await transport.pull(since: 0, limit: 1) }
        respond(500, "boom")
        await #expect(throws: SyncTransportError.server(status: 500, message: "boom")) { try await transport.push([]) }
    }
}
