---
name: verify-main
description: Check, verify, review or test commits that came in with a git pull (or any commit range) in the Daybook repo - list them, scan for this project's known risks, run unit, build, smoke, SQL and end-to-end sync checks, then try the new features in the simulator. Use after a pull, before a release, or when asked whether new work on main is OK.
---

# Verify new commits on main

Daybook's main branch gets work pushed from more than one place. After a `git pull`, check the
new range before building on it. Paths are relative to the repo root.

## 1. Run the automated checks

```bash
.claude/skills/verify-main/verify.sh <old-head> [new-head]   # e.g. the range git pull printed: 146f2c5 aadc425
```

It prints the commits, a **risk scan** of the diff, and a summary of: unit tests, build, smoke test
(simulator, via `run-daybook`), and, if Docker is running, the SQL tests and the end-to-end sync
test. Logs go to `.build/verify/`. Exit status 1 if anything failed. Takes about 5 minutes.
Start Docker first (`open -a Docker`) or those two show as SKIP.

## 2. Look into every risk flag

The scan is a heuristic: read the code behind each flag and say whether it is real.

| Flag | What to check |
|---|---|
| Touches Supabase Auth users | The Supabase project is **shared with the user's other app**: users, email templates, redirect URLs and rate limits are project-wide. Deleting or changing auth users affects that app too. Raise it with the user; don't decide. |
| Migration in `public` / no grants | Daybook's objects belong in the `daybook` schema with explicit grants (`authenticated`, `service_role`); see `supabase/migrations`. |
| Migration edited | Fine before it was applied anywhere; after `supabase db push` it needs a new migration. Ask whether it was applied. |
| Store opened for writing without `.update` | Other processes (widget, share extension, intents with the app closed) must write via `SQLiteStore.update { }`: one transaction, recorded for sync. |
| Raw SQL writes in TaskStore | To-do data must go through `SQLiteStore.write` → `SyncLog.record`; sync bookkeeping (meta, outbox, tombstones) may not. |
| Bundle ID / App Group / URL scheme | Existing installs lose data (the database lives in the App Group) or links stop working. |
| New target | Needs a signing team and its own App Group entitlement on a device. |
| Permission / background mode | Usage text is clear and honest; App Review will ask about background modes. |

## 3. Try what changed in the simulator

The smoke test only covers quick add. For each commit, try its feature with the `run-daybook`
driver (`D=.claude/skills/run-daybook/driver.sh`), and check results with `$D db "<sql>"`, not
just the screen:

| Area changed | How to try it |
|---|---|
| Lists, rows, quick add, drag + | `$D launch --fresh`, navigate with `tap`, `ui`, `ss`; `drag-path` for drags |
| Widget (`Widget/`) | `$D widget-add medium`, then tap a check circle by position; `db` to confirm |
| Reminders, notification actions | add a to-do with a time + `allow`, then `$D notify "<title>" Tomorrow` |
| Share extension (`Share/`) | `$D share-url <url>`, tap Today/Add by position |
| Changes made outside the app | note `$D pid`, change it elsewhere, reopen the app, check `pid` is unchanged and the change shows |
| Links (`daybook://…`) | `xcrun simctl openurl booted 'daybook://…'`, tap Open on the confirmation |
| Onboarding | `$D launch --fresh --onboarding` |
| Sync, sign-in, account | end-to-end test covers the engine and SQL; sign-in needs a real Supabase project (`App/Sources/Store/AppConfig.swift`). If it isn't configured, say sign-in is untested. |
| Siri / Shortcuts / Spotlight / Control Center | can't be driven from here; build success plus code reading only. Say so. |

## 4. Report

1. The commits, one line each.
2. A results table (automated checks + what you tried by hand).
3. Each risk flag: real or not, and why. Real ones that need a decision go to the user.
4. **What wasn't tested**, plainly.

Don't commit, push or "fix" pulled work without asking; report first.
