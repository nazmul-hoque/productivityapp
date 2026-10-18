#!/usr/bin/env bash
# End-to-end sync test: Postgres with the Supabase migrations, PostgREST in front (as on
# Supabase), and the Swift sync engine as two devices of one user plus a second user.
# Needs Docker. Usage: scripts/test-sync-e2e.sh [swift-image]
set -euo pipefail
cd "$(dirname "$0")/.."
image="${1:-swift-sqlite:6.0}"
secret="test-secret-that-is-at-least-32-characters-long"
user_a=00000000-0000-0000-0000-00000000000a
user_b=00000000-0000-0000-0000-00000000000b

pg="productivity-e2e-pg-$$"
rest="productivity-e2e-rest-$$"
docker run -d --rm --name "$pg" --network host -e POSTGRES_PASSWORD=test postgres:16 >/dev/null
trap 'docker stop "$rest" "$pg" >/dev/null 2>&1 || true' EXIT
until docker exec "$pg" pg_isready -U postgres -q; do sleep 0.5; done
sleep 1
psql() { docker exec -i "$pg" psql -U postgres -q -v ON_ERROR_STOP=1 "$@"; }
psql < supabase/tests/supabase_mock.sql >/dev/null
for migration in supabase/migrations/*.sql; do psql < "$migration" >/dev/null; done
psql -c "insert into auth.users (id) values ('$user_a'), ('$user_b')" >/dev/null

docker run -d --rm --name "$rest" --network host \
    -e PGRST_DB_URI="postgres://authenticator:authenticator@localhost:5432/postgres" \
    -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon -e PGRST_JWT_SECRET="$secret" \
    -e PGRST_SERVER_PORT=3000 postgrest/postgrest:v12.2.3 >/dev/null
until curl -s -o /dev/null --noproxy localhost http://localhost:3000/; do sleep 0.5; done

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
jwt() {
    local header payload signature
    header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
    payload=$(printf '{"sub":"%s","role":"authenticated","exp":%d}' "$1" $(( $(date +%s) + 3600 )) | b64url)
    signature=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -hmac "$2" -binary | b64url)
    echo "$header.$payload.$signature"
}

docker run --rm --network host -v "$PWD/Packages/TaskCore":/pkg -w /pkg \
    -e NO_PROXY=localhost -e no_proxy=localhost \
    -e SYNC_E2E_URL=http://localhost:3000 \
    -e SYNC_E2E_TOKEN_A="$(jwt "$user_a" "$secret")" \
    -e SYNC_E2E_TOKEN_B="$(jwt "$user_b" "$secret")" \
    -e SYNC_E2E_TOKEN_BAD="$(jwt "$user_a" "wrong-secret-wrong-secret-wrong-secret")" \
    "$image" swift test --filter SyncEndToEndTests
