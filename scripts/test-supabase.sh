#!/usr/bin/env bash
# Applies the Supabase migrations to a throwaway Postgres (Docker) and runs supabase/tests.
# Usage: scripts/test-supabase.sh
set -euo pipefail
cd "$(dirname "$0")/.."

name="daybook-pg-test-$$"
docker run -d --rm --name "$name" -e POSTGRES_PASSWORD=test postgres:16 >/dev/null
trap 'docker stop "$name" >/dev/null' EXIT
until docker exec "$name" pg_isready -U postgres -q; do sleep 0.5; done
sleep 1

psql() { docker exec -i "$name" psql -U postgres -q -v ON_ERROR_STOP=1 "$@"; }
psql < supabase/tests/supabase_mock.sql
for migration in supabase/migrations/*.sql; do
    psql < "$migration"
done
psql < supabase/tests/sync_test.sql
