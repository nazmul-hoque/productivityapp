import CoreTransferable
import SwiftUI
import TaskCore
import UniformTypeIdentifiers

/// Export a backup or a CSV, and import from Daybook backups, Todoist, TickTick, Google Tasks
/// and Apple Reminders. Imports are previewed before anything changes.
struct DataView: View {
    @Environment(AppStore.self) private var store
    @State private var choosingFiles = false
    @State private var pending: PendingImport?
    @State private var problems: [String] = []
    @State private var result: String?
    @State private var readingReminders = false

    var body: some View {
        Form {
            Section {
                ShareLink(item: BackupFile(db: store.db), preview: SharePreview("Daybook backup")) {
                    Label("Export a Backup", systemImage: "externaldrive")
                }
                ShareLink(item: CSVFile(db: store.db), preview: SharePreview("Daybook to-dos (CSV)")) {
                    Label("Export To-Dos as CSV", systemImage: "tablecells")
                }
            } header: {
                Text("Export")
            } footer: {
                Text("A backup has everything, including completed and trashed to-dos, and can be imported again. The CSV opens in Numbers, Excel or Google Sheets.")
            }

            Section {
                Button {
                    choosingFiles = true
                } label: {
                    Label("Import from Files…", systemImage: "doc.badge.plus")
                }
                Button {
                    importReminders()
                } label: {
                    HStack {
                        Label("Import from Reminders…", systemImage: "checklist")
                        if readingReminders { Spacer(); ProgressView() }
                    }
                }
                .disabled(readingReminders)
            } header: {
                Text("Import")
            } footer: {
                Text("""
                    Files: a Daybook backup; a Todoist project exported as a CSV template (one file per project); \
                    a TickTick backup (Settings → Account → Generate Backup); or Tasks.json from Google Takeout (unzip it first). \
                    You can pick several at once. Reminders imports your open reminders and leaves them as they are. \
                    Things doesn't export its data, so it can't be imported yet.
                    """)
            }

            if let result {
                Section {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            if !problems.isEmpty {
                Section("Couldn't import") {
                    ForEach(problems, id: \.self) { Text($0).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Import & Export")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $choosingFiles,
                      allowedContentTypes: [.json, .commaSeparatedText, .plainText, .text, .data],
                      allowsMultipleSelection: true) { outcome in
            switch outcome {
            case .success(let urls): readFiles(urls)
            case .failure(let error): problems = [error.localizedDescription]
            }
        }
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { pending in
            Button("Import") { apply(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    // MARK: - Importing

    private func readFiles(_ urls: [URL]) {
        result = nil
        problems = []
        var combined = TaskDatabase()
        var sources: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let (format, database) = try Importer.read(data, fileName: url.lastPathComponent, today: store.today)
                combined.merge(database, today: store.today)
                sources.append(format.displayName)
            } catch {
                problems.append("\(url.lastPathComponent): \(error)")
            }
        }
        guard !sources.isEmpty else { return }
        prepare(combined, from: Array(Set(sources)).sorted().joined(separator: ", "))
    }

    private func importReminders() {
        result = nil
        problems = []
        readingReminders = true
        Task {
            defer { readingReminders = false }
            do {
                let items = try await RemindersReader.openReminders()
                guard !items.isEmpty else {
                    problems = ["There are no open reminders to import."]
                    return
                }
                prepare(RemindersImport.database(from: items, today: store.today), from: "Reminders")
            } catch {
                problems = [error.localizedDescription]
            }
        }
    }

    /// Works out what the import would add, without changing anything yet.
    private func prepare(_ database: TaskDatabase, from source: String) {
        var preview = store.db
        let summary = preview.merge(database, today: store.today)
        guard summary.todos + summary.projects + summary.areas > 0 else {
            result = summary.skipped > 0 ? "Everything in it is already here." : "There was nothing to import."
            return
        }
        pending = PendingImport(source: source, database: database, summary: summary)
    }

    private func apply(_ pending: PendingImport) {
        var summary = ImportSummary()
        let today = store.today
        store.perform { summary = $0.merge(pending.database, today: today) }
        result = "Imported \(PendingImport.describe(summary)) from \(pending.source)."
        self.pending = nil
    }
}

/// An import waiting for confirmation.
private struct PendingImport: Identifiable {
    let id = UUID()
    let source: String
    let database: TaskDatabase
    let summary: ImportSummary

    var title: String { "Import from \(source)?" }

    var message: String {
        var text = "This adds \(Self.describe(summary)) to Daybook."
        if summary.skipped > 0 { text += " \(summary.skipped) already here will be skipped." }
        return text
    }

    static func describe(_ summary: ImportSummary) -> String {
        func count(_ n: Int, _ noun: String) -> String? { n == 0 ? nil : "\(n) \(noun)\(n == 1 ? "" : "s")" }
        let parts = [count(summary.todos, "to-do"), count(summary.projects, "project"), count(summary.areas, "area"), count(summary.tags, "tag")]
            .compactMap { $0 }
        return ListFormatter.localizedString(byJoining: parts)
    }
}

// MARK: - Export files

/// The backup, written to a temporary file when the share sheet asks for it.
struct BackupFile: Transferable {
    let db: TaskDatabase

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            SentTransferredFile(try write(DaybookExport.json(file.db), named: "Daybook Backup \(stamp()).json"))
        }
    }
}

struct CSVFile: Transferable {
    let db: TaskDatabase

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { file in
            SentTransferredFile(try write(Data(DaybookExport.csv(file.db).utf8), named: "Daybook To-Dos \(stamp()).csv"))
        }
    }
}

private func write(_ data: Data, named name: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try data.write(to: url, options: .atomic)
    return url
}

private func stamp() -> String {
    LocalDay(Date()).description
}
