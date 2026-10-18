-- Tests for 20261019090000_delete_account.sql. Run with scripts/test-supabase.sh.
\set ON_ERROR_STOP on

insert into auth.users (id) values
    ('00000000-0000-0000-0000-0000000000c1'),
    ('00000000-0000-0000-0000-0000000000c2');

create function pg_temp.check(ok boolean, what text) returns void language plpgsql as $$
begin
    if ok is not true then raise exception 'FAILED: %', what; end if;
    raise notice 'ok - %', what;
end $$;

set role authenticated;

select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false);
select daybook.sync_push('[{"entity":"todo","id":"c1c1c1c1-0000-0000-0000-000000000001",
    "fields":{"title":"Mine"},"clocks":{"title":"0000000000001000-0000-a"}}]');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c2', false);
select daybook.sync_push('[{"entity":"todo","id":"c2c2c2c2-0000-0000-0000-000000000001",
    "fields":{"title":"Theirs"},"clocks":{"title":"0000000000001000-0000-b"}}]');

-- C1 deletes their account: their records and their user go, C2's stay.
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000000c1', false);
select daybook.delete_account();
select pg_temp.check((select count(*) = 0 from daybook.sync_pull(0)), 'deleted account has no records');
reset role;
select pg_temp.check((select count(*) = 0 from auth.users where id = '00000000-0000-0000-0000-0000000000c1'), 'auth user deleted');
select pg_temp.check((select count(*) = 1 from daybook.sync_records where user_id = '00000000-0000-0000-0000-0000000000c2'),
                     'other users untouched');
set role authenticated;

-- A deleted user's still-valid token can't write again (the user no longer exists).
do $$
begin
    perform daybook.sync_push('[{"entity":"todo","id":"c1c1c1c1-0000-0000-0000-000000000002","fields":{},"clocks":{}}]');
    raise exception 'FAILED: deleted user could push';
exception when foreign_key_violation then
    raise notice 'ok - deleted user cannot push';
end $$;

-- Signed out: refused.
select set_config('request.jwt.claim.sub', '', false);
do $$
begin
    perform daybook.delete_account();
    raise exception 'FAILED: anonymous delete allowed';
exception when sqlstate '28000' then
    raise notice 'ok - anonymous delete refused';
end $$;

reset role;
\echo 'all delete-account tests passed'
