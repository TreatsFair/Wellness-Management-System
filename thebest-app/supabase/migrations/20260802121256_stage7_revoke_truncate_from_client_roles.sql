-- Stage 7: revoke TRUNCATE from client-facing roles.
--
-- Rationale
-- ---------
-- PostgreSQL row-level security governs SELECT / INSERT / UPDATE / DELETE only.
-- TRUNCATE is *not* filtered by RLS policies -- it is authorised purely by the
-- TRUNCATE table privilege. Supabase's stock `GRANT ALL ... TO authenticated`
-- therefore leaves every client-facing role able to empty a table outright,
-- regardless of how restrictive its policies are.
--
-- Verified empirically on staging (inside a rolled-back transaction): a table
-- with RLS enabled and no permissive policy still truncated successfully while
-- `set role authenticated` was in effect.
--
-- Concretely this meant a staff JWT could not forge or edit a row in
-- `transactions` (admin-only RLS), but could delete every row in it -- and in
-- `audit_log`, destroying the record of having done so.
--
-- This migration removes TRUNCATE from `authenticated`, `anon` and PUBLIC on
-- all current tables in schema `public`, and corrects the default privileges so
-- future tables do not re-acquire it.
--
-- Deliberately NOT touched: `postgres`, `service_role`, the table owner, and
-- Supabase-internal administration roles all retain TRUNCATE.
--
-- Applied as a single unit by the migration runner; no explicit BEGIN/COMMIT,
-- matching the other Stage 7 migrations.

-- 1. Current tables ---------------------------------------------------------
-- Restricted to ordinary/partitioned tables (relkind r, p). Views and foreign
-- tables are skipped: TRUNCATE is not a meaningful privilege on them.
do $$
declare
  v_rel regclass;
  v_count integer := 0;
begin
  for v_rel in
    select c.oid::regclass
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
    order by c.relname
  loop
    execute format('revoke truncate on table %s from authenticated, anon, public', v_rel);
    v_count := v_count + 1;
  end loop;

  raise notice 'stage7: revoked TRUNCATE on % public table(s)', v_count;
end $$;

-- 2. Default privileges for the table-creating owner roles -------------------
-- All 30 existing public tables are owned by `postgres`, which is the role the
-- migration tooling connects as, so this is the entry that governs new tables.
alter default privileges for role postgres in schema public
  revoke truncate on tables from authenticated, anon, public;

-- `supabase_admin` also carries a default-ACL entry for schema public that
-- grants TRUNCATE to authenticated/anon. Altering it requires membership of
-- supabase_admin, which the migration role does not hold on a managed project.
-- Attempt it, and degrade to a notice rather than failing the migration if the
-- platform does not permit it.
do $$
begin
  execute 'alter default privileges for role supabase_admin in schema public '
       || 'revoke truncate on tables from authenticated, anon, public';
  raise notice 'stage7: supabase_admin default privileges corrected';
exception
  when insufficient_privilege or undefined_object then
    raise notice 'stage7: cannot alter supabase_admin default privileges (%) '
                 '-- tables created by supabase_admin in schema public must be '
                 'checked by the periodic TRUNCATE audit instead', sqlerrm;
end $$;

-- 3. Post-condition ----------------------------------------------------------
-- Fail the migration loudly if any client-facing TRUNCATE grant survives.
do $$
declare
  v_leaks text;
begin
  select string_agg(c.relname || ' (' || r.rolname || ')', ', ' order by c.relname)
  into v_leaks
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  cross join (values ('authenticated'), ('anon')) as r(rolname)
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
    and has_table_privilege(r.rolname, c.oid, 'TRUNCATE');

  if v_leaks is not null then
    raise exception 'stage7: TRUNCATE still held by client roles on: %', v_leaks;
  end if;

  raise notice 'stage7: verified -- authenticated/anon hold TRUNCATE on no public table';
end $$;
