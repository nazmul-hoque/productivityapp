import SwiftUI
import TaskStore

/// Sign in with email, and see how syncing is going.
struct AccountView: View {
    @Environment(SyncController.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var working = false
    @State private var confirmingSignOut = false
    @FocusState private var focused: Field?

    enum Field { case email, code }

    var body: some View {
        NavigationStack {
            Form {
                switch sync.account {
                case .unavailable:
                    unavailable
                case .signedOut:
                    signIn
                case .awaitingLink(let email):
                    checkEmail(email)
                case .signedIn(let email):
                    signedIn(email)
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .animation(.default, value: sync.account)
        }
    }

    // MARK: - States

    private var unavailable: some View {
        Section {
            Label("Sync isn't set up in this build", systemImage: "icloud.slash")
        } footer: {
            Text("Your to-dos are stored on this device. Add the Supabase project in AppConfig.swift to sign in and sync.")
        }
    }

    @ViewBuilder
    private var signIn: some View {
        Section {
            TextField("Email", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .email)
                .submitLabel(.send)
                .onSubmit(sendLink)
        } header: {
            Text("Sync across your devices")
        } footer: {
            Text("We'll email you a sign-in link and a code. No password needed. Your to-dos stay on this device until you choose what to do with them.")
        }
        errorSection
        Section {
            Button(action: sendLink) {
                HStack {
                    Text("Email Me a Sign-In Link")
                    if working { Spacer(); ProgressView() }
                }
            }
            .disabled(!looksLikeEmail || working)
        }
        .onAppear { focused = .email }
    }

    @ViewBuilder
    private func checkEmail(_ address: String) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check your email").font(.headline)
                    Text("We sent a link to \(address). Open it on this device, or enter the code from the same email.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "envelope.badge")
            }
        }
        Section {
            TextField("6-digit code", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .focused($focused, equals: .code)
            Button {
                run { await sync.verify(code: code) }
            } label: {
                HStack {
                    Text("Sign In")
                    if working { Spacer(); ProgressView() }
                }
            }
            .disabled(code.filter(\.isNumber).count < 6 || working)
        }
        errorSection
        Section {
            Button("Send Again") { run { await sync.sendLink(to: address) } }
                .disabled(working)
            Button("Use a Different Email") {
                code = ""
                sync.startOver()
            }
        }
    }

    @ViewBuilder
    private func signedIn(_ address: String?) -> some View {
        Section("Signed in") {
            Label(address ?? "Signed in", systemImage: "person.crop.circle.fill")
        }
        Section {
            SyncStatusRow(status: sync.status)
            Button {
                Task { await sync.syncNow() }
            } label: {
                Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(sync.status == .syncing)
        } header: {
            Text("Sync")
        } footer: {
            Text("Changes sync automatically when you edit, open the app, and come back to it.")
        }
        Section {
            Button("Sign Out", role: .destructive) { confirmingSignOut = true }
        }
        .confirmationDialog("Sign out on this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await sync.signOut() } }
        } message: {
            Text("Your to-dos stay on this device but stop syncing.")
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = sync.signInError {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Helpers

    private var looksLikeEmail: Bool {
        let parts = email.trimmingCharacters(in: .whitespaces).split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !parts[0].isEmpty
    }

    private func sendLink() {
        guard looksLikeEmail else { return }
        run {
            await sync.sendLink(to: email)
            if case .awaitingLink = sync.account { focused = .code }
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        working = true
        Task {
            await action()
            working = false
        }
    }
}

/// "Synced 2 minutes ago", "Syncing…", or what went wrong.
struct SyncStatusRow: View {
    let status: SyncController.Status

    var body: some View {
        switch status {
        case .idle:
            Label("Waiting to sync", systemImage: "icloud")
                .foregroundStyle(.secondary)
        case .syncing:
            Label {
                Text("Syncing…")
            } icon: {
                ProgressView()
            }
        case .synced(let date):
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Label("Synced \(date.formatted(.relative(presentation: .named)))", systemImage: "checkmark.icloud")
            }
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.icloud")
                .foregroundStyle(.red)
        }
    }
}

/// The account button in the sidebar: shows whether you're signed in and if sync has a problem.
struct AccountBadge: View {
    @Environment(SyncController.self) private var sync

    var body: some View {
        switch (sync.account, sync.status) {
        case (.signedIn, .failed):
            Label("Account, sync problem", systemImage: "exclamationmark.icloud")
                .foregroundStyle(.red)
        case (.signedIn, .syncing):
            Label("Account, syncing", systemImage: "arrow.triangle.2.circlepath.icloud")
        case (.signedIn, _):
            Label("Account", systemImage: "checkmark.icloud")
        default:
            Label("Account", systemImage: "person.crop.circle")
        }
    }
}
