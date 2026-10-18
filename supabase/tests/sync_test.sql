-- Tests for 20261018120000_sync.sql. Run with scripts/test-supabase.sh.
-- Each check raises an exception on failure, which stops the script with a non-zero exit.
\set ON_ERROR_STOP on

insert into auth.users (id) values
    ('00000000-0000-0000-0000-00000000000a'),
    ('00000000-0000-0000-0000-00000000000b');

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
    if ok is not true then raise exception 'FAILED: %', what; end if;
    raise notice 'ok - %', what;
end $$;

create function pg_temp.act_as(uid text) returns void language plpgsql as $$
begin
    perform set_config('request.jwt.claim.sub', uid, false);
end $$;

set role authenticated;

-- A new record is stored and pulled back.
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select daybook.sync_push('[{"entity":"todo","id":"11111111-1111-1111-1111-111111111111",
    "fields":{"title":"Report","notes":"n"},"clocks":{"title":"0000000000001000-0000-a","notes":"0000000000001000-0000-a"},
    "deleted":false}]');
select pg_temp.check((select count(*) = 1 and min(fields ->> 'title') = 'Report' from daybook.sync_pull(0)), 'push then pull');

-- An older clock loses; a newer clock on another field wins; untouched fields stay.
select daybook.sync_push('[{"entity":"todo","id":"11111111-1111-1111-1111-111111111111",
    "fields":{"title":"Stale","notes":"newer notes"},"clocks":{"title":"0000000000000999-0000-b","notes":"0000000000002000-0000-b"}}]');
select pg_temp.check((select fields ->> 'title' = 'Report' and fields ->> 'notes' = 'newer notes'
                      and clocks ->> 'notes' = '0000000000002000-0000-b' from daybook.sync_pull(0)), 'field-level last writer wins');

-- Pushing the same thing again doesn't create a new version.
select max(version) as v1 from daybook.sync_pull(0) \gset
select daybook.sync_push('[{"entity":"todo","id":"11111111-1111-1111-1111-111111111111",
    "fields":{"title":"Report"},"clocks":{"title":"0000000000001000-0000-a"}}]');
select pg_temp.check((select max(version) = :v1 from daybook.sync_pull(0)), 'idempotent push keeps the version');
select pg_temp.check((select count(*) = 0 from daybook.sync_pull(:v1)), 'nothing new after the cursor');

-- Clocks compare as plain text whatever the database collation: digits before letters.
select daybook.sync_push('[{"entity":"tag","id":"22222222-2222-2222-2222-222222222222",
    "fields":{"title":"a"},"clocks":{"title":"0000000000005000-0000-Z"}}]');
select daybook.sync_push('[{"entity":"tag","id":"22222222-2222-2222-2222-222222222222",
    "fields":{"title":"b"},"clocks":{"title":"0000000000005000-0000-a"}}]');
select pg_temp.check((select fields ->> 'title' = 'b' from daybook.sync_pull(0) where entity = 'tag'), 'byte-order clock comparison');

-- Deletion wins over a later edit, and drops the fields.
select daybook.sync_push('[{"entity":"todo","id":"11111111-1111-1111-1111-111111111111",
    "fields":{},"clocks":{"_deleted":"0000000000003000-0000-a"},"deleted":true}]');
select daybook.sync_push('[{"entity":"todo","id":"11111111-1111-1111-1111-111111111111",
    "fields":{"title":"Revived?"},"clocks":{"title":"0000000000009000-0000-b"}}]');
select pg_temp.check((select deleted and fields = '{}'::jsonb and clocks ->> '_deleted' = '0000000000003000-0000-a'
                      from daybook.sync_pull(0) where entity = 'todo'), 'delete wins');

-- Untracked fields fill gaps but don't overwrite.
select daybook.sync_push('[{"entity":"area","id":"33333333-3333-3333-3333-333333333333",
    "fields":{"title":"Work"},"clocks":{"title":"0000000000001000-0000-a"}}]');
select daybook.sync_push('[{"entity":"area","id":"33333333-3333-3333-3333-333333333333",
    "fields":{"title":"Legacy","order":"V"},"clocks":{}}]');
select pg_temp.check((select fields ->> 'title' = 'Work' and fields ->> 'order' = 'V'
                      from daybook.sync_pull(0) where entity = 'area'), 'untracked fields fill gaps only');

-- Pages come oldest first and respect the limit.
select pg_temp.check((select count(*) = 2 from daybook.sync_pull(0, 2)), 'page limit');
select pg_temp.check((select bool_and(v) from (select version > lag(version, 1, 0::bigint) over (order by version) as v
                      from daybook.sync_pull(0)) x), 'pull is ordered by version');

-- Another user sees nothing of A's, through the function or the table.
select pg_temp.act_as('00000000-0000-0000-0000-00000000000b');
select pg_temp.check((select count(*) = 0 from daybook.sync_pull(0)), 'other user pulls nothing');
select pg_temp.check((select count(*) = 0 from daybook.sync_records), 'row-level security hides other users');

-- B's push of the same ids creates B's own records.
select daybook.sync_push('[{"entity":"area","id":"33333333-3333-3333-3333-333333333333",
    "fields":{"title":"Home"},"clocks":{"title":"0000000000001000-0000-c"}}]');
select pg_temp.act_as('00000000-0000-0000-0000-00000000000a');
select pg_temp.check((select fields ->> 'title' = 'Work' from daybook.sync_pull(0) where entity = 'area'), 'users are isolated');

-- Direct writes are refused; only sync_push writes.
do $$
begin
    insert into daybook.sync_records (entity, id, version) values ('todo', gen_random_uuid(), 1);
    raise exception 'FAILED: direct insert was allowed';
exception when insufficient_privilege then
    raise notice 'ok - direct insert refused';
end $$;

-- Bad input is rejected.
do $$
begin
    perform daybook.sync_push('[{"entity":"spaceship","id":"44444444-4444-4444-4444-444444444444","fields":{},"clocks":{}}]');
    raise exception 'FAILED: unknown entity accepted';
exception when check_violation then
    raise notice 'ok - unknown entity rejected';
end $$;

-- Signed out: refused.
select pg_temp.act_as('');
do $$
begin
    perform daybook.sync_push('[]');
    raise exception 'FAILED: anonymous push allowed';
exception when sqlstate '28000' then
    raise notice 'ok - anonymous push refused';
end $$;

reset role;
\echo 'all sync tests passed'
