import Foundation
import TaskStore

/// Build-time settings.
enum AppConfig {
    /// The Supabase project to sync with: *Project Settings → API* in the Supabase dashboard.
    /// The anon key is meant to ship in apps (row-level security protects the data); never put
    /// the `service_role` key here. `nil` builds the app without sign-in and sync.
    static let supabase: SupabaseConfig? = nil
    // static let supabase: SupabaseConfig? = SupabaseConfig(
    //     url: URL(string: "https://<project-ref>.supabase.co")!,
    //     anonKey: "<anon public key>",
    //     schema: "daybook")  // the default; must be an exposed schema (supabase/README.md)

    /// Other apps that sign in with the same Supabase project, so share Daybook's accounts.
    /// Deleting an account deletes it for them too; the Delete Account screen names them.
    static let appsSharingAccounts: [String] = []

    /// Where sign-in links in emails lead: this app, through its URL scheme. Must also be listed
    /// in Supabase under *Authentication → URL Configuration → Redirect URLs*.
    static let authRedirect = URL(string: "daybook://auth-callback")!
}
