# Supabase backend

The server side of sync: one table, `sync_records`, holding each synced record's fields as JSON
with a clock per field, and two functions the app calls through the REST API:

- `sync_push(records jsonb)` merges records into the caller's data, field by field (newer clock
  wins, deletion always wins). One push per user runs at a time.
- `sync_pull(since bigint, max_records int)` returns the caller's records changed after a version.

Row-level security limits every user to their own rows; there are no write policies, so clients
can only write through `sync_push`. The data itself lives on each device in SQLite; this is the
meeting point. The same merge rules are implemented in the app (`TaskStore/Sync/SyncRecord.swift`).

## Set up a project

1. Create a project at <https://supabase.com/dashboard> (any region near your users).
2. Install the CLI (`brew install supabase/tap/supabase`), then from the repo root:
   ```
   supabase login
   supabase link --project-ref <your-project-ref>
   supabase db push          # applies supabase/migrations
   ```
3. *Authentication → Providers*: enable **Email** (magic links). Apple and Google come with the
   sign-in work in the app.
4. *Project Settings → API*: note the **Project URL** and the **anon public** key. These go in the
   app's config. Never put the `service_role` key in the app.

## Tests

- `scripts/test-supabase.sh` — applies the migrations to a throwaway Postgres (Docker) with a
  minimal stand-in for Supabase's `auth` schema (`supabase/tests/supabase_mock.sql`) and runs
  `supabase/tests/sync_test.sql`: merging, idempotency, ordering, isolation between users, refused
  direct writes and anonymous calls.
- `scripts/test-sync-e2e.sh` — the same database behind PostgREST (Supabase's REST layer), with
  the Swift sync engine as two devices of one user and a second user.
