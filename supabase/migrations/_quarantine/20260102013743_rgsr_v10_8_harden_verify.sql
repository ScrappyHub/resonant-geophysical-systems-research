-- ============================================================
-- RGSR v10.8 HARDEN + VERIFY (NO LEAKAGE)
-- - Hardens grants
-- - Verifies/repairs required RLS policies
-- - Optional FK attachments via introspection (no assumptions)
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 0) Defensive grants (RLS is the gate; grants should be minimal)
-- ------------------------------------------------------------
-- NOTE: Supabase uses roles: anon, authenticated, service_role.
-- We allow authenticated to use schema; table access remains RLS-controlled.

do $do$
begin
  -- schema usage
  execute 'revoke all on schema rgsr from public';
  execute 'grant usage on schema rgsr to authenticated';
  execute 'grant usage on schema rgsr to service_role';
exception when undefined_schema then null;
end
$do$;

-- Tables: REVOKE broad grants; RLS policies decide row access
do $do$
declare t record;
begin
  for t in
    select table_schema, table_name
    from information_schema.tables
    where table_schema='rgsr' and table_type='BASE TABLE'
  loop
    execute format('revoke all on table %I.%I from public', t.table_schema, t.table_name);
    execute format('revoke all on table %I.%I from anon', t.table_schema, t.table_name);
    -- authenticated gets table privileges as needed, but RLS still gates rows
    execute format('grant select, insert, update, delete on table %I.%I to authenticated', t.table_schema, t.table_name);
    execute format('grant select, insert, update, delete on table %I.%I to service_role', t.table_schema, t.table_name);
  end loop;
end
$do$;

-- ------------------------------------------------------------
-- 1) Ensure RLS is enabled on core tables
-- ------------------------------------------------------------
do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='labs') then
    execute 'alter table rgsr.labs enable row level security';
  end if;
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='lab_members') then
    execute 'alter table rgsr.lab_members enable row level security';
  end if;
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='runs') then
    execute 'alter table rgsr.runs enable row level security';
  end if;
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='run_measurements') then
    execute 'alter table rgsr.run_measurements enable row level security';
  end if;
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='run_artifacts') then
    execute 'alter table rgsr.run_artifacts enable row level security';
  end if;
end
$do$;

-- ------------------------------------------------------------
-- 2) Verify policies exist (create if missing) — NO LEAKAGE
-- ------------------------------------------------------------
-- We do NOT assume earlier migrations created them cleanly.
-- We add missing policies only; names are stable canonical.

-- labs_select
do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='labs') then
    if not exists (select 1 from pg_policies where schemaname='rgsr' and tablename='labs' and policyname='labs_select') then
      execute $$create policy labs_select on rgsr.labs for select to authenticated
        using (rgsr.can_read_lane(lane, lab_id)
          or exists (select 1 from rgsr.lab_members m where m.lab_id = labs.lab_id and m.user_id = rgsr.me() and m.is_active = true)
        );$$;
    end if;
    if not exists (select 1 from pg_policies where schemaname='rgsr' and tablename='labs' and policyname='labs_write') then
      execute $$create policy labs_write on rgsr.labs for all to authenticated
        using (rgsr.can_write()) with check (rgsr.can_write());$$;
    end if;
  end if;
end
$do$;

-- lab_members policies
do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='lab_members') then
    if not exists (select 1 from pg_policies where schemaname='rgsr' and tablename='lab_members' and policyname='lm_select') then
      execute $$create policy lm_select on rgsr.lab_members for select to authenticated
        using (user_id = rgsr.me() or rgsr.can_write());$$;
    end if;
    if not exists (select 1 from pg_policies where schemaname='rgsr' and tablename='lab_members' and policyname='lm_write') then
      execute $$create policy lm_write on rgsr.lab_members for all to authenticated
        using (rgsr.can_write()) with check (rgsr.can_write());$$;
    end if;
  end if;
end
$do$;

-- runs policies
do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='runs') then
    if not exists (select 1 from pg_policies where schemaname='rgsr' and tablename='runs' and policyname='runs_select') then
      execute $$create policy runs_select on rgsr.runs for select to authenticated
        using (rgsr.can_read_lane(lane, lab_id));$$;
    end if;
    if not exists (select 1 from pg_policies where schemaname='rgsr' and tablename='runs' and policyname='runs_write') then
      execute $$create policy runs_write on rgsr.runs for all to authenticated
        using (rgsr.can_write()) with check (rgsr.can_write());$$;
    end if;
  end if;
end
$do$;

-- run_measurements policies (inherit from parent run)
do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='run_measurements') then
    if not exists (select 1 from pg_policies where schemaname='rgsr' and tablename='run_measurements' and policyname='rm_select') then
      execute $$create policy rm_select on rgsr.run_measurements for select to authenticated
        using (exists (select 1 from rgsr.runs r where r.run_id = run_measurements.run_id and rgsr.can_read_lane(r.lane, r.lab_id)));$$;
    end if;
    if not exists (select 1 from pg_policies where schemaname='rgsr' and tablename='run_measurements' and policyname='rm_write') then
      execute $$create policy rm_write on rgsr.run_measurements for all to authenticated
        using (rgsr.can_write()) with check (rgsr.can_write());$$;
    end if;
  end if;
end
$do$;

-- run_artifacts policies (inherit from parent run)
do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='run_artifacts') then
    if not exists (select 1 from pg_policies where schemaname='rgsr' and tablename='run_artifacts' and policyname='ra_select') then
      execute $$create policy ra_select on rgsr.run_artifacts for select to authenticated
        using (exists (select 1 from rgsr.runs r where r.run_id = run_artifacts.run_id and rgsr.can_read_lane(r.lane, r.lab_id)));$$;
    end if;
    if not exists (select 1 from pg_policies where schemaname='rgsr' and tablename='run_artifacts' and policyname='ra_write') then
      execute $$create policy ra_write on rgsr.run_artifacts for all to authenticated
        using (rgsr.can_write()) with check (rgsr.can_write());$$;
    end if;
  end if;
end
$do$;

commit;
-- ============================================================
-- End migration
-- ============================================================
