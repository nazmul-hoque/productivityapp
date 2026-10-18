import SwiftUI
import TaskCore
import TaskStore
import UIKit
import UniformTypeIdentifiers
import WidgetKit

/// The share sheet entry: turns a shared link or text into a to-do.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel()
        let host = UIHostingController(rootView: ShareView(model: model, done: { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        Task { await model.load(from: items) }
    }
}

@MainActor
@Observable
final class ShareModel {
    var title = ""
    var notes = ""
    var today = false
    var error: String?

    /// Fills the form from what was shared: a page's title and URL, or plain text.
    func load(from items: [NSExtensionItem]) async {
        var url: URL?
        var text: String?
        for item in items {
            for provider in item.attachments ?? [] {
                if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
                } else if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
                }
            }
            // Safari puts the page title here.
            if text == nil, let content = item.attributedContentText?.string, !content.isEmpty {
                text = content
            }
        }
        let firstLine = text?.split(separator: "\n", maxSplits: 1).first.map(String.init)
        title = firstLine ?? url?.host() ?? ""
        notes = [url?.absoluteString, text.flatMap { $0 == firstLine ? nil : $0 }]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

    /// Adds the to-do to the shared database. Returns `false` (with `error` set) if it couldn't.
    func save() -> Bool {
        guard let url = SharedStore.databaseURL else {
            error = "Open Daybook once before sharing to it."
            return false
        }
        let todo = Todo(title: title.trimmingCharacters(in: .whitespacesAndNewlines), notes: notes,
                        when: today ? .on(LocalDay(Date())) : .inbox)
        do {
            try SQLiteStore(url: url).update { $0.add(todo, today: LocalDay(Date())) }
            WidgetCenter.shared.reloadAllTimelines()
            return true
        } catch {
            self.error = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    let done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $model.title, axis: .vertical)
                    .font(.headline)
                TextField("Notes", text: $model.notes, axis: .vertical)
                    .lineLimit(2...6)
                    .foregroundStyle(.secondary)
                Picker("Add to", selection: $model.today) {
                    Label("Inbox", systemImage: "tray.fill").tag(false)
                    Label("Today", systemImage: "star.fill").tag(true)
                }
                .pickerStyle(.inline)
                if let error = model.error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("New To-Do")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { if model.save() { done() } }
                        .bold()
                        .disabled(model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
