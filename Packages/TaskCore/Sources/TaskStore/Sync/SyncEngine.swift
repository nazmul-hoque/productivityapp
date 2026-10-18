import Foundation

/// The server side of sync, as the engine sees it.
public protocol SyncTransport: Sendable {
    /// Sends local changes; the server merges them field by field.
    func push(_ records: [SyncRecord]) async throws
    /// Records changed on the server after `cursor`, in order, at most `limit` of them.
    func pull(since cursor: Int64, limit: Int) async throws -> SyncPage
}

public struct SyncPage: Sendable {
    public var records: [SyncRecord]
    /// The position of the last record returned (or `cursor` if none).
    public var cursor: Int64

    public init(records: [SyncRecord], cursor: Int64) {
        self.records = records
        self.cursor = cursor
    }
}

public struct SyncResult: Sendable, Equatable {
    public var pushed: Int
    public var pulled: Int
    /// Whether local data changed, so the app should reload it.
    public var changedLocally: Bool
}

/// Runs a sync: push the outbox, then pull and merge everything newer than the cursor.
///
/// Push first, so the pull brings back the merged result of this device's changes too. A sync
/// that fails part way is safe to repeat: pushes are idempotent merges, the outbox is only cleared
/// for what the server accepted, and the cursor only moves with a successful merge.
public actor SyncEngine {
    private let store: SQLiteStore
    private let transport: any SyncTransport
    private let pageSize: Int

    public init(store: SQLiteStore, transport: any SyncTransport, pageSize: Int = 500) {
        self.store = store
        self.transport = transport
        self.pageSize = pageSize
    }

    public func sync() async throws -> SyncResult {
        let (records, upTo) = try await store.pendingChanges()
        for start in stride(from: 0, to: records.count, by: pageSize) {
            try await transport.push(Array(records[start..<min(start + pageSize, records.count)]))
        }
        if !records.isEmpty { try await store.markPushed(upTo: upTo) }

        // Collect every page before merging: a to-do may arrive before the project it belongs to.
        var cursor = try await store.syncCursor()
        var pulled: [SyncRecord] = []
        while true {
            let page = try await transport.pull(since: cursor, limit: pageSize)
            pulled += page.records
            cursor = page.cursor
            if page.records.count < pageSize { break }
        }
        let changed = try await store.applyRemote(pulled, cursor: cursor)
        return SyncResult(pushed: records.count, pulled: pulled.count, changedLocally: changed)
    }
}
