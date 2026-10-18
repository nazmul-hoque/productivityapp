-- Sync storage for the app: one row per synced record (area, tag, project, heading, to-do) per user.
--
-- The app keeps the real data in SQLite on the device; this table holds each record's fields as
-- JSON with a clock per field (a hybrid logical clock, ordered as plain text). sync_push merges
-- incoming records field by field, keeping the newer clock, and a deletion always wins. Each change
-- gets a new version from a sequence; sync_pull returns a user's records after a given version.
-- The same rules are implemented on the device in TaskStore (SyncRecord.merge).

create table public.sync_records (
    user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
    entity text not null check (entity in ('area', 'tag', 'project', 'heading', 'todo')),
    id uuid not null,
    fields jsonb not null default '{}'::jsonb check (jsonb_typeof(fields) = 'object'),
    clocks jsonb not null default '{}'::jsonb check (jsonb_typeof(clocks) = 'object'),
    deleted boolean not null default false,
    version bigint not null,
    updated_at timestamptz not null default now(),
    primary key (user_id, entity, id)
);

create index sync_records_user_version on public.sync_records (user_id, version);

create sequence public.sync_version;

alter table public.sync_records enable row level security;

-- People can read their own records. There are no write policies: writes go through sync_push only.
create policy "Users read their own records" on public.sync_records
    for select to authenticated
    using (user_id = (select auth.uid()));

-- Merges a batch of records ({entity, id, fields, clocks, deleted}) into the caller's data.
create function public.sync_push(records jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    uid uuid := auth.uid();
    incoming jsonb;
    incoming_deleted boolean;
    existing public.sync_records%rowtype;
    field text;
    incoming_clock text;
    new_fields jsonb;
    new_clocks jsonb;
    new_deleted boolean;
begin
    if uid is null then
        raise exception 'not authenticated' using errcode = '28000';
    end if;
    if jsonb_typeof(records) is distinct from 'array' then
        raise exception 'records must be a JSON array' using errcode = '22023';
    end if;
    if jsonb_array_length(records) > 1000 then
        raise exception 'at most 1000 records per push' using errcode = '22023';
    end if;

    -- One push at a time per user, so a user's versions are assigned and committed in order and
    -- a pull can never skip a change that commits later with a lower version.
    perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));

    for incoming in select value from jsonb_array_elements(records) loop
        incoming_deleted := coalesce((incoming ->> 'deleted')::boolean, false);
        if jsonb_typeof(coalesce(incoming -> 'fields', '{}')) <> 'object'
            or jsonb_typeof(coalesce(incoming -> 'clocks', '{}')) <> 'object' then
            raise exception 'fields and clocks must be JSON objects' using errcode = '22023';
        end if;

        select * into existing
        from public.sync_records r
        where r.user_id = uid and r.entity = incoming ->> 'entity' and r.id = (incoming ->> 'id')::uuid
        for update;

        if not found then
            insert into public.sync_records (user_id, entity, id, fields, clocks, deleted, version)
            values (
                uid,
                incoming ->> 'entity',
                (incoming ->> 'id')::uuid,
                case when incoming_deleted then '{}'::jsonb else coalesce(incoming -> 'fields', '{}') end,
                coalesce(incoming -> 'clocks', '{}'),
                incoming_deleted,
                nextval('public.sync_version')
            );
            continue;
        end if;

        if existing.deleted or incoming_deleted then
            -- Deletion wins; keep only the latest deletion clock.
            new_deleted := true;
            new_fields := '{}'::jsonb;
            new_clocks := jsonb_build_object('_deleted', coalesce(
                greatest(existing.clocks ->> '_deleted' collate "C", incoming -> 'clocks' ->> '_deleted' collate "C"), ''));
        else
            new_deleted := false;
            new_fields := existing.fields;
            new_clocks := existing.clocks;
            for field, incoming_clock in select key, value from jsonb_each_text(coalesce(incoming -> 'clocks', '{}')) loop
                if (incoming_clock collate "C") > (coalesce(new_clocks ->> field, '') collate "C") then
                    new_clocks := new_clocks || jsonb_build_object(field, incoming_clock);
                    new_fields := new_fields || jsonb_build_object(field, coalesce(incoming -> 'fields' -> field, 'null'::jsonb));
                end if;
            end loop;
            -- Fields sent without a clock (written before change tracking) only fill gaps.
            new_fields := (coalesce(incoming -> 'fields', '{}') - array(select jsonb_object_keys(new_fields))) || new_fields;
        end if;

        if new_fields is distinct from existing.fields
            or new_clocks is distinct from existing.clocks
            or new_deleted is distinct from existing.deleted then
            update public.sync_records r
            set fields = new_fields,
                clocks = new_clocks,
                deleted = new_deleted,
                version = nextval('public.sync_version'),
                updated_at = now()
            where r.user_id = uid and r.entity = existing.entity and r.id = existing.id;
        end if;
    end loop;
end;
$$;

-- The caller's records changed after version `since`, oldest first.
create function public.sync_pull(since bigint default 0, max_records integer default 500)
returns table (entity text, id uuid, fields jsonb, clocks jsonb, deleted boolean, version bigint)
language sql
stable
security invoker
set search_path = ''
as $$
    select r.entity, r.id, r.fields, r.clocks, r.deleted, r.version
    from public.sync_records r
    where r.user_id = (select auth.uid()) and r.version > since
    order by r.version
    limit least(greatest(max_records, 1), 1000);
$$;

revoke all on function public.sync_push(jsonb) from public, anon;
revoke all on function public.sync_pull(bigint, integer) from public, anon;
grant execute on function public.sync_push(jsonb) to authenticated;
grant execute on function public.sync_pull(bigint, integer) to authenticated;
revoke all on table public.sync_records from anon;
revoke insert, update, delete on table public.sync_records from authenticated;
grant select on table public.sync_records to authenticated;
