import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import TaskStore

/// Answers requests with a canned response and remembers the last request.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (status: Int, body: String) = (200, "")
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.response.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
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
    let transport: SupabaseTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return SupabaseTransport(config: SupabaseConfig(url: URL(string: "https://example.supabase.co")!, anonKey: "anon-key"),
                                 session: URLSession(configuration: configuration),
                                 accessToken: { "user-token" })
    }()

    @Test func pushCallsTheFunctionWithRecords() async throws {
        StubProtocol.response = (204, "")
        let id = UUID()
        try await transport.push([SyncRecord(entity: .todo, id: id, fields: ["title": .string("Hi")], clocks: ["title": "c1"])])

        let request = try #require(StubProtocol.lastRequest)
        #expect(request.url?.absoluteString == "https://example.supabase.co/rest/v1/rpc/sync_push")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "apikey") == "anon-key")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer user-token")
        let body = try JSONDecoder().decode([String: [SyncRecord]].self, from: try #require(StubProtocol.lastBody))
        #expect(body["records"]?.first?.id == id)
        #expect(body["records"]?.first?.fields["title"] == .string("Hi"))
    }

    @Test func pullDecodesRowsAndAdvancesTheCursor() async throws {
        StubProtocol.response = (200, """
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
        let body = try JSONSerialization.jsonObject(with: try #require(StubProtocol.lastBody)) as? [String: Int]
        #expect(body == ["since": 40, "max_records": 2])
    }

    @Test func emptyPullKeepsTheCursor() async throws {
        StubProtocol.response = (200, "[]")
        #expect(try await transport.pull(since: 7, limit: 500).cursor == 7)
    }

    @Test func errorsAreReported() async throws {
        StubProtocol.response = (401, #"{"message":"JWT expired"}"#)
        await #expect(throws: SyncTransportError.unauthorized) { try await transport.pull(since: 0, limit: 1) }
        StubProtocol.response = (500, "boom")
        await #expect(throws: SyncTransportError.server(status: 500, message: "boom")) { try await transport.push([]) }
    }
}
