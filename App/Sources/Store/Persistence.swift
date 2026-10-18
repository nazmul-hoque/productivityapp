import Foundation
import TaskCore

/// Stores the database as a JSON file in Application Support.
///
/// Interim storage for the offline-only phase; it will be replaced by SQLite plus the
/// sync engine in Phase 2.
struct Persistence {
    var url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = folder.appendingPathComponent("database.json")
        }
    }

    func load() -> TaskDatabase? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(TaskDatabase.self, from: data)
        } catch {
            // Keep the unreadable file for recovery rather than silently overwriting it.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            print("Could not read database, moved to \(backup.lastPathComponent): \(error)")
            return nil
        }
    }

    func save(_ db: TaskDatabase) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(db).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            print("Could not save database: \(error)")
        }
    }
}
