-- Just enough of Supabase for testing the migrations on plain Postgres: the auth schema with
-- auth.users and auth.uid(), and the anon/authenticated roles. Not for use on Supabase itself.
create role anon nologin;
create role authenticated nologin;
create schema auth;
grant usage on schema auth to anon, authenticated;
create table auth.users (id uuid primary key);
-- Like Supabase's: the JWT's `sub`, from PostgREST's request settings.
create function auth.uid() returns uuid language sql stable as $$
    select nullif(coalesce(current_setting('request.jwt.claim.sub', true),
                           (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')), '')::uuid
$$;
-- The role PostgREST logs in as, switching to anon/authenticated per request.
create role authenticator login password 'authenticator' noinherit;
grant anon, authenticated to authenticator;
grant usage on schema public to anon, authenticated;
