import Foundation
import TaskCore
import TaskStore

/// Data access for App Intents. They run in the app's process: when the app is running they go
/// through its store (so the screen updates and sync follows); otherwise through the database file.
@MainActor
enum IntentData {
    private static var store: AppStore? { AppDelegate.shared?.store }

    static func database() throws -> TaskDatabase {
        if let store { return store.db }
        return try SQLiteStore(url: Persistence.databaseURL).load()
    }

    static var today: LocalDay { store?.today ?? LocalDay(Date()) }

    static func add(title: String, notes: String?, when: DaybookLink.AddWhen?) async throws -> (Todo, TaskDatabase) {
        let today = today
        if let store {
            var added: Todo!
            store.perform { added = $0.add(title: title, notes: notes, when: when, today: today) }
            await store.save()
            return (added, store.db)
        }
        var added: Todo!
        let db = try SQLiteStore(url: Persistence.databaseURL).update { added = $0.add(title: title, notes: notes, when: when, today: today) }
        return (added, db)
    }

    static func complete(_ id: UUID) async throws -> TaskDatabase {
        if let store {
            store.complete(id)
            await store.save()
            return store.db
        }
        return try SQLiteStore(url: Persistence.databaseURL).update { _ = $0.complete(id) }
    }
}
