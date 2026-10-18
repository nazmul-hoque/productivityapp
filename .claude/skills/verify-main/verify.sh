#!/usr/bin/env bash
# Checks a range of commits (usually what a `git pull` brought in): lists them, scans the diff for
# this project's known risks, and runs every automated check. Prints a summary at the end.
# Run from the repo root: .claude/skills/verify-main/verify.sh <base> [head]   (head defaults to HEAD)
set -uo pipefail

base=${1:?usage: verify.sh <base-commit> [head]}
head=${2:-HEAD}
D=.claude/skills/run-daybook/driver.sh
logs=.build/verify; mkdir -p "$logs"
results=()
record() { results+=("$(printf '%-22s %s' "$1" "$2")"); }

echo "== Commits $base..$head"
git log --format='%h %an, %ar: %s' "$base..$head"
echo
git diff --stat "$base..$head" | tail -1
echo

# --- Risk scan: things that have bitten this project, or would --------------------------------
echo "== Risks"
added() { git diff "$base..$head" -U0 -- "$@" | grep '^+[^+]' || true; }
risks=0
flag() { echo "- $1"; risks=$((risks + 1)); }

# Shared Supabase project: Auth is shared with the user's other app.
if added supabase App Packages | grep -qiE 'auth\.users|auth\.admin|/auth/v1/(admin|user)'; then
  flag "Touches Supabase Auth users: the project's users are shared with another app (see supabase/README.md, Sharing a project)."
fi
# Migrations: everything belongs in the daybook schema; applied migrations must not change.
for f in $(git diff --name-only --diff-filter=A "$base..$head" -- supabase/migrations); do
  if git show "$head:$f" | grep -E '\bpublic\.' | grep -vqE 'from public|to public'; then
    flag "$f creates objects in public; use the daybook schema."
  fi
  git show "$head:$f" | grep -qE '^\s*grant ' || flag "$f has no grants; new functions/tables need explicit ones (authenticated, service_role)."
done
for f in $(git diff --name-only --diff-filter=M "$base..$head" -- supabase/migrations); do
  flag "$f was edited after being committed; if it was already applied (supabase db push), add a new migration instead."
done
# Writers outside the app must go through SQLiteStore.update (one transaction, tracked for sync).
if added Widget Share App/Sources/Intents Shared | grep -E 'SQLiteStore\(url:' | grep -vqE '\.(update|load)\b|readingFrom'; then
  flag "A widget/extension/intent opens the store for writing without .update { }: check it is tracked for sync and transactional."
fi
if added Packages/TaskCore/Sources/TaskStore | grep -qE 'db\.execute\(sql: *"(INSERT|UPDATE|DELETE)'; then
  flag "New raw SQL writes in TaskStore: make sure they also go through SyncLog.record (or are sync bookkeeping)."
fi
# Identity and permissions.
if added project.yml '*.entitlements' Shared/SharedStore.swift | grep -qE 'BUNDLE_IDENTIFIER|group\.|CFBundleURLSchemes'; then
  flag "Bundle IDs, App Group or URL scheme changed: existing installs lose their data or links."
fi
if added project.yml | grep -qE '^\+  [A-Za-z]+:$'; then
  flag "New target in project.yml: it needs a signing team (and App Group) on a device."
fi
if added project.yml App/Info.plist | grep -qE 'NS[A-Za-z]+UsageDescription|UIBackgroundModes|BGTaskScheduler'; then
  flag "New permission or background mode: check the usage text and App Store review notes."
fi
[ "$risks" -eq 0 ] && echo "- none found"
echo

# --- Automated checks ---------------------------------------------------------------------------
echo "== Unit tests"
if swift test --package-path Packages/TaskCore >"$logs/unit.log" 2>&1; then
  record "Unit tests" "PASS ($(grep -oE 'with [0-9]+ tests' "$logs/unit.log" | tail -1 | grep -oE '[0-9]+') tests)"
else
  record "Unit tests" "FAIL (see $logs/unit.log)"
fi

echo "== Build"
if "$D" build >"$logs/build.log" 2>&1 && grep -q 'BUILD SUCCEEDED' "$logs/build.log"; then
  record "Build" "PASS"
  echo "== Smoke test"
  if "$D" smoke >"$logs/smoke.log" 2>&1; then record "Smoke test" "PASS"; else record "Smoke test" "FAIL (see $logs/smoke.log)"; fi
else
  record "Build" "FAIL (see $logs/build.log)"
  record "Smoke test" "SKIP (no build)"
fi

if docker info >/dev/null 2>&1; then
  echo "== SQL tests"
  if scripts/test-supabase.sh >"$logs/sql.log" 2>&1; then record "SQL tests" "PASS"; else record "SQL tests" "FAIL (see $logs/sql.log)"; fi
  echo "== End-to-end sync"
  if scripts/test-sync-e2e.sh >"$logs/e2e.log" 2>&1; then record "End-to-end sync" "PASS"; else record "End-to-end sync" "FAIL (see $logs/e2e.log)"; fi
else
  record "SQL tests" "SKIP (Docker not running: open -a Docker)"
  record "End-to-end sync" "SKIP (Docker not running)"
fi

echo
echo "== Summary ($base..$head, $risks risk flag(s))"
printf '%s\n' "${results[@]}"
printf '%s\n' "${results[@]}" | grep -q 'FAIL' && exit 1 || exit 0
