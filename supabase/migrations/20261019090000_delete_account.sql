-- Lets people delete their account from the app, as the App Store requires of apps with sign-up.
--
-- Deletes the caller's Daybook records and their Supabase Auth user (which also ends their
-- sessions). The project's users are shared with any other app using it, so this removes the
-- sign-in for those apps too, and anything they store against the user with ON DELETE CASCADE.

create function daybook.delete_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := auth.uid();
begin
    if uid is null then
        raise exception 'not authenticated' using errcode = '28000';
    end if;
    -- Explicit, though the foreign key would cascade: Daybook's data goes even if that changes.
    delete from daybook.sync_records where user_id = uid;
    delete from auth.users where id = uid;
end;
$$;

revoke all on function daybook.delete_account() from public, anon;
grant execute on function daybook.delete_account() to authenticated, service_role;
