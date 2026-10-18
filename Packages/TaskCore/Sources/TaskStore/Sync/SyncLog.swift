import Foundation
import GRDB
import TaskCore

/// Local bookkeeping for sync, kept in the same SQLite file and updated in the same transaction
/// as the rows it describes:
///
/// - `sync_clock`: the HLC of each field's last change, per row.
/// - `sync_outbox`: rows changed since they were last pushed, with a sequence number.
/// - `sync_tombstone`: rows deleted here (or remotely), so the deletion syncs and sticks.
/// - `meta`: this device's node id, its last clock, the outbox counter and the pull cursor.
enum SyncLog {
    // MARK: - Recording local changes

    /// Records a local change: new clocks for the changed fields, outbox entries, tombstones.
    static func record(_ changes: Changes, in db: Database) throws {
        guard !changes.fieldChanges.isEmpty || !changes.removedKeys.isEmpty else { return }
        let clock = try tick(db).description
        for change in changes.fieldChanges {
            for field in change.fields {
                try setClock(clock, change.entity, change.id, field, in: db)
            }
            try db.execute(sql: "DELETE FROM sync_tombstone WHERE entity = ? AND id = ?",
                           arguments: [change.entity.rawValue, change.id.uuidString])
            try enqueue(change.entity, change.id, in: db)
        }
        for (entity, id) in changes.removedKeys {
            try tombstone(entity, id, clock: clock, in: db)
            try enqueue(entity, id, in: db)
        }
    }

    // MARK: - Pushing

    /// Records waiting to be pushed, and the outbox position they cover.
    static func pending(in db: Database) throws -> (records: [SyncRecord], upTo: Int64) {
        let rows = try Row.fetchAll(db, sql: "SELECT entity, id, seq FROM sync_outbox ORDER BY seq")
        guard !rows.isEmpty else { return ([], 0) }
        let snapshot = try FieldSnapshot(Rows.loadAll(db))
        let tombstones = try self.tombstones(in: db)
        var records: [SyncRecord] = []
        var upTo: Int64 = 0
        for row in rows {
            upTo = max(upTo, row["seq"])
            guard let entity = Entity(rawValue: row["entity"]), let id = UUID(uuidString: row["id"]) else { continue }
            if let clock = tombstones[Key(entity, id)] {
                records.append(.tombstone(entity, id: id, clock: clock))
            } else if let fields = snapshot[entity, id] {
                records.append(SyncRecord(entity: entity, id: id, fields: fields, clocks: try clocks(entity, id, in: db)))
            }
            // Neither: the row was created and deleted without a tombstone (replaced data); nothing to send.
        }
        return (records, upTo)
    }

    /// Clears outbox entries up to `seq`. Rows changed again since then have a higher number and
    /// stay queued, so a change made during a push isn't lost.
    static func markPushed(upTo seq: Int64, in db: Database) throws {
        try db.execute(sql: "DELETE FROM sync_outbox WHERE seq <= ?", arguments: [seq])
    }

    // MARK: - Pulling

    static func cursor(in db: Database) throws -> Int64 {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'sync_cursor'").flatMap { Int64($0) } ?? 0
    }

    /// Merges records from the server into the local rows. Returns whether anything visible changed.
    static func apply(_ remote: [SyncRecord], cursor: Int64, in db: Database) throws -> Bool {
        defer { try? setMeta("sync_cursor", String(cursor), in: db) }
        guard !remote.isEmpty else { return false }

        let current = try Rows.loadAll(db)
        let snapshot = try FieldSnapshot(current)
        let tombstones = try self.tombstones(in: db)
        var rows = snapshot.rows
        var last = try lastClock(in: db)
        let node = try nodeID(in: db)

        for record in remote {
            for clock in record.clocks.values.compactMap(HLC.init) {
                last = HLC.receive(clock, last: last, node: node)
            }
            let key = Key(record.entity, record.id)
            var local: SyncRecord?
            if let clock = tombstones[key] {
                local = .tombstone(record.entity, id: record.id, clock: clock)
            } else if let fields = snapshot[record.entity, record.id] {
                local = SyncRecord(entity: record.entity, id: record.id, fields: fields,
                                   clocks: try clocks(record.entity, record.id, in: db))
            }
            let merged = SyncRecord.merge(local, record)

            try db.execute(sql: "DELETE FROM sync_clock WHERE entity = ? AND id = ?", arguments: [record.entity.rawValue, record.id.uuidString])
            if merged.deleted {
                rows[record.entity]?[record.id] = nil
                try tombstone(record.entity, record.id, clock: merged.clocks[SyncRecord.deletedField] ?? "", in: db)
            } else {
                rows[record.entity, default: [:]][record.id] = merged.fields
                for (field, clock) in merged.clocks {
                    try setClock(clock, record.entity, record.id, field, in: db)
                }
            }
            // Local fields newer than the server's still need pushing; otherwise this row is in sync.
            if merged == record || (merged.deleted && record.deleted) {
                try db.execute(sql: "DELETE FROM sync_outbox WHERE entity = ? AND id = ?", arguments: [record.entity.rawValue, record.id.uuidString])
            } else {
                try enqueue(record.entity, record.id, in: db)
            }
        }
        if let last { try setMeta("sync_hlc", last.description, in: db) }

        let merged = try RecordAssembly.database(from: rows)
        try SQLiteStore.writeRows(Changes(from: current, to: merged), in: db)
        // Fix references broken by the merge, as a local change so other devices get the fix too.
        let repaired = RecordAssembly.repaired(merged)
        if repaired != merged {
            try SQLiteStore.write(Changes(from: merged, to: repaired), in: db)
        }
        return repaired != current
    }

    // MARK: - Helpers

    private struct Key: Hashable {
        var entity: Entity
        var id: UUID
        init(_ entity: Entity, _ id: UUID) {
            self.entity = entity
            self.id = id
        }
    }

    private static func tombstones(in db: Database) throws -> [Key: String] {
        var result: [Key: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT entity, id, clock FROM sync_tombstone") {
            if let entity = Entity(rawValue: row["entity"]), let id = UUID(uuidString: row["id"]) {
                result[Key(entity, id)] = row["clock"]
            }
        }
        return result
    }

    private static func clocks(_ entity: Entity, _ id: UUID, in db: Database) throws -> [String: String] {
        var clocks: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT field, clock FROM sync_clock WHERE entity = ? AND id = ?",
                                    arguments: [entity.rawValue, id.uuidString]) {
            clocks[row["field"]] = row["clock"]
        }
        return clocks
    }

    private static func setClock(_ clock: String, _ entity: Entity, _ id: UUID, _ field: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO sync_clock (entity, id, field, clock) VALUES (?, ?, ?, ?)
            ON CONFLICT(entity, id, field) DO UPDATE SET clock = excluded.clock
            """, arguments: [entity.rawValue, id.uuidString, field, clock])
    }

    private static func tombstone(_ entity: Entity, _ id: UUID, clock: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM sync_clock WHERE entity = ? AND id = ?", arguments: [entity.rawValue, id.uuidString])
        try db.execute(sql: """
            INSERT INTO sync_tombstone (entity, id, clock) VALUES (?, ?, ?)
            ON CONFLICT(entity, id) DO UPDATE SET clock = max(clock, excluded.clock)
            """, arguments: [entity.rawValue, id.uuidString, clock])
    }

    private static func enqueue(_ entity: Entity, _ id: UUID, in db: Database) throws {
        let seq = (try meta("sync_outbox_seq", in: db).flatMap { Int64($0) } ?? 0) + 1
        try setMeta("sync_outbox_seq", String(seq), in: db)
        try db.execute(sql: """
            INSERT INTO sync_outbox (entity, id, seq) VALUES (?, ?, ?)
            ON CONFLICT(entity, id) DO UPDATE SET seq = excluded.seq
            """, arguments: [entity.rawValue, id.uuidString, seq])
    }

    /// The next clock for a local change.
    private static func tick(_ db: Database) throws -> HLC {
        let clock = HLC.tick(after: try lastClock(in: db), now: Date(), node: try nodeID(in: db))
        try setMeta("sync_hlc", clock.description, in: db)
        return clock
    }

    private static func lastClock(in db: Database) throws -> HLC? {
        try meta("sync_hlc", in: db).flatMap(HLC.init)
    }

    /// A random id for this device's clocks, created on first use. Shared by the app and its
    /// extensions, which are the same device.
    static func nodeID(in db: Database) throws -> String {
        if let node = try meta("sync_node", in: db) { return node }
        let node = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        try setMeta("sync_node", node, in: db)
        return node
    }

    private static func meta(_ key: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
    }

    private static func setMeta(_ key: String, _ value: String, in db: Database) throws {
        try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", arguments: [key, value])
    }
}
