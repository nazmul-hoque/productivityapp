import Foundation
import Testing
import TaskCore
@testable import TaskStore

/// The real sync engine against the real SQL functions, through PostgREST (what Supabase's REST
/// API is). Runs only under scripts/test-sync-e2e.sh, which starts the servers and provides
/// tokens for two users; skipped otherwise.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SYNC_E2E_URL"] != nil))
struct SyncEndToEndTests {
    let today = LocalDay(iso: "2026-10-14")!

    func transport(_ tokenVariable: String) -> SupabaseTransport {
        let env = ProcessInfo.processInfo.environment
        let url = URL(string: env["SYNC_E2E_URL"]!)!
        let token = env[tokenVariable]!
        return SupabaseTransport(config: SupabaseConfig(url: url, anonKey: "test", restURL: url), accessToken: { token })
    }

    @Test func twoDevicesConvergeThroughTheServer() async throws {
        let phone = try Device(server: transport("SYNC_E2E_TOKEN_A"))
        var todoID: UUID!
        var headingID: UUID!
        try phone.edit { db in
            let project = db.addProject(Project(title: "Launch", deadline: today.adding(days: 9)))
            headingID = db.addHeading("Prep", toProject: project.id).id
            let rule = RepeatRule(frequency: .weekly([.monday, .thursday]), anchor: today, reminder: TimeOfDay(hour: 9, minute: 30))
            todoID = db.add(Todo(title: "Standup", notes: "**notes**", projectID: project.id, when: .on(today), isEvening: true,
                                 repetition: Repetition(rule: rule, occurrence: today), tagIDs: [db.tag(named: "Work").id],
                                 checklist: [ChecklistItem(title: "Agenda", isDone: true)]), today: today).id
            db.add(Todo(title: "Ünïcode ✓ \"quotes\""), today: today)
        }
        try await phone.sync()

        let laptop = try Device(server: transport("SYNC_E2E_TOKEN_A"))
        try await laptop.sync()
        #expect(try laptop.db == phone.db)

        // Concurrent edits to different fields, and a heading deleted while a to-do moves under it.
        try phone.edit { $0.modify(todoID) { $0.title = "Daily standup" }; $0.removeHeading(headingID) }
        try laptop.edit { $0.modify(todoID) { $0.headingID = headingID; $0.deadline = self.today.adding(days: 1) } }
        try await phone.sync()
        try await laptop.sync()
        try await phone.sync()

        let merged = try phone.db.todos[todoID]!
        #expect(merged.title == "Daily standup")
        #expect(merged.deadline == today.adding(days: 1))
        #expect(merged.headingID == nil)
        #expect(try phone.db == laptop.db)

        // Another account sees none of it.
        let stranger = try Device(server: transport("SYNC_E2E_TOKEN_B"))
        let result = try await stranger.sync()
        #expect(result.pulled == 0)
        #expect(try stranger.db.todos.isEmpty)
    }

    @Test func badTokenIsUnauthorized() async throws {
        let device = try Device(server: transport("SYNC_E2E_TOKEN_BAD"))
        await #expect(throws: SyncTransportError.unauthorized) { try await device.sync() }
    }
}
