import Foundation
import TaskCore
import TaskStore

/// Where the database lives and how it is opened on launch.
///
/// The SQLite file sits in the App Group container so the app, widgets and the share
/// extension can all open it. If the container is unavailable (e.g. a build without
/// the entitlement), it falls back to the app's own Application Support folder.
enum Persistence {
    static var databaseURL: URL {
        SharedStore.databaseURL
            ?? applicationSupport.appendingPathComponent("Database", isDirectory: true).appendingPathComponent("tasks.sqlite")
    }

    /// The JSON file used before SQLite.
    static var legacyJSONURL: URL {
        applicationSupport.appendingPathComponent("database.json")
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    /// Opens the store and loads its contents. A new store is filled once from the old JSON
    /// file if there is one, otherwise with the sample project.
    static func open(today: LocalDay) -> (store: SQLiteStore?, database: TaskDatabase) {
        do {
            let store = try SQLiteStore(url: databaseURL)
            if try !store.isInitialized() {
                let initial = importLegacyJSON() ?? SampleData.database(today: today)
                try store.initialize(with: initial)
                retireLegacyJSON()
                return (store, initial)
            }
            return (store, try store.load())
        } catch {
            // Keep the app usable; changes this session won't be saved.
            print("Could not open database at \(databaseURL.path): \(error)")
            return (nil, importLegacyJSON() ?? SampleData.database(today: today))
        }
    }

    private static func importLegacyJSON() -> TaskDatabase? {
        guard let data = try? Data(contentsOf: legacyJSONURL) else { return nil }
        do {
            return try JSONDecoder().decode(TaskDatabase.self, from: data)
        } catch {
            print("Could not read \(legacyJSONURL.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Keeps the old file (renamed) rather than deleting it, in case it is needed for recovery.
    private static func retireLegacyJSON() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyJSONURL.path) else { return }
        let retired = legacyJSONURL.deletingPathExtension().appendingPathExtension("migrated.json")
        try? fm.removeItem(at: retired)
        try? fm.moveItem(at: legacyJSONURL, to: retired)
    }
}
