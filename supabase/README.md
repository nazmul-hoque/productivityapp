# Supabase backend

The server side of sync, all in the `daybook` schema: one table, `sync_records`, holding each synced record's fields as JSON
with a clock per field, and two functions the app calls through the REST API:

- `sync_push(records jsonb)` merges records into the caller's data, field by field (newer clock
  wins, deletion always wins). One push per user runs at a time.
- `sync_pull(since bigint, max_records int)` returns the caller's records changed after a version.
- `delete_account()` deletes the caller's records and their user (see below).

Row-level security limits every user to their own rows; there are no write policies, so clients
can only write through `sync_push`. The data itself lives on each device in SQLite; this is the
meeting point. The same merge rules are implemented in the app (`TaskStore/Sync/SyncRecord.swift`).

Keeping everything in its own schema lets Daybook share a Supabase project with other apps without
name clashes. The app picks the schema with PostgREST's `Content-Profile` header
(`SupabaseConfig.schema`, `daybook` by default).

## Set up a project

1. Create a project at <https://supabase.com/dashboard> (any region near your users), or use an
   existing one (see *Sharing a project* below).
2. Install the CLI (`brew install supabase/tap/supabase`), then from the repo root:
   ```
   supabase login
   supabase link --project-ref <your-project-ref>
   supabase db push          # applies supabase/migrations
   ```
   Then, under *Project Settings → API → Exposed schemas* (Data API settings), add `daybook`. The
   REST API only serves the schemas listed there; without it sync fails with a 404 or 406.
3. *Authentication → Providers*: make sure **Email** is enabled. Apple and Google come later.
4. *Authentication → URL Configuration*: add `daybook://auth-callback` to **Redirect URLs**.
   Sign-in links lead there, which opens the app.
5. *Authentication → Emails → Templates*: in both **Confirm signup** (first sign-in) and **Magic
   Link**, add the code next to the link, so people can sign in when they open the email on
   another device. If the project is shared, word them for every app (the link returns to whichever
   app asked). For example:
   ```html
   <h2>Your sign-in link</h2>
   <p><a href="{{ .ConfirmationURL }}">Sign in</a></p>
   <p>Or enter this code in the app: <strong>{{ .Token }}</strong></p>
   ```
6. *Project Settings → API*: copy the **Project URL** and the **anon public** key into
   `App/Sources/Store/AppConfig.swift`. The anon key is meant to ship in apps; never put the
   `service_role` key in the app.

## Sharing a project

The `daybook` schema keeps the data apart, but everything under *Authentication* is project-wide:

- **One user list.** Someone who signs up in Daybook is a user of every app on the project, and
  the other way round. Check the other apps' row-level security: a policy that allows any
  `authenticated` user would let Daybook's users read that data.
- **Email templates are shared.** Step 5 changes the *Magic Link* and *Confirm signup* emails for
  every app. Word them for all of them, or leave them alone: sign-in links still work, but the
  6-digit code won't be in the email.
- **Redirect URLs** are one list; adding `daybook://auth-callback` next to other apps' is fine.
- **Email rate limits** are shared.
- **Deleting a user** deletes their Daybook data too (`on delete cascade` from `auth.users`).

The default email sender is rate limited (a few emails an hour) and meant for testing. Before
real users, set up custom SMTP under *Project Settings → Authentication*.

## Deleting accounts

The App Store requires apps with sign-up to let people delete their account in the app:
*Account → Delete Account*. It calls `daybook.delete_account()`, which deletes the caller's
records and their Supabase Auth user, ending their sessions everywhere. Because the project's users
are shared, this also removes the sign-in for any other app on the project, along with anything that
app stores against the user with `on delete cascade`. To-dos on the device stay there, unsynced.
List those apps in `AppConfig.appsSharingAccounts` so the Delete Account screen names them in its
warning.

## Tests

- `scripts/test-supabase.sh` — applies the migrations to a throwaway Postgres (Docker) with a
  minimal stand-in for Supabase's `auth` schema (`supabase/tests/supabase_mock.sql`) and runs
  `supabase/tests/sync_test.sql`: merging, idempotency, ordering, isolation between users, refused
  direct writes and anonymous calls.
- `scripts/test-sync-e2e.sh` — the same database behind PostgREST (Supabase's REST layer), with
  the Swift sync engine as two devices of one user and a second user. On macOS the Swift tests run
  natively; on Linux they run in a Swift image whose SQLite has the snapshot API (first argument,
  default `swift-sqlite:6.0`).
