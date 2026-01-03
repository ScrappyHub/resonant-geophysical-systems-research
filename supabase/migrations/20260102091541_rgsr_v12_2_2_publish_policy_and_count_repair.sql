-- ============================================================
-- RGSR v12.2.2 — REPAIR
-- 1) Fix invalid policy syntax (no "for insert, update, delete")
-- 2) Recreate approved_submission_count safely (publish_submissions optional)
-- ============================================================

begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 1) FIX POLICIES: rgsr.projects (split by command)
-- ------------------------------------------------------------
do $do$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname='rgsr' and tablename='projects'
      and policyname in ('projects_write_own','projects_insert_own','projects_update_own','projects_delete_own')
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end
$do$;

-- NOTE: assumes you already have rgsr.actor_uid() and rgsr.can_write() and owner_uid column.
-- If your table uses owner_uid, this is correct. If it uses created_by, swap accordingly.

create policy projects_insert_own on rgsr.projects
for insert to authenticated
with check (owner_uid = rgsr.actor_uid());

create policy projects_update_own on rgsr.projects
for update to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

create policy projects_delete_own on rgsr.projects
for delete to authenticated
using (owner_uid = rgsr.actor_uid());

-- Admin override (keep if you already had it; otherwise create it)
do $do$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname='rgsr' and tablename='projects' and policyname='projects_admin'
  ) then
    execute $p$
      create policy projects_admin on rgsr.projects
      for all to authenticated
      using (rgsr.can_write())
      with check (rgsr.can_write());
    $p$;
  end if;
end
$do$;

-- ------------------------------------------------------------
-- 2) SAFE approved_submission_count()
--    DO NOT hard-reference rgsr.publish_submissions if missing.
-- ------------------------------------------------------------
create or replace function rgsr.approved_submission_count(p_uid uuid)
returns bigint
language plpgsql
stable
as $fn$
declare
  v_cnt bigint := 0;
  v_has_publish boolean := false;
begin
  if p_uid is null then
    return 0;
  end if;

  select coalesce(count(*),0) into v_cnt
  from rgsr.forum_posts fp
  where fp.created_by = p_uid and fp.is_approved = true;

  v_cnt := v_cnt + coalesce((
    select count(*)
    from rgsr.research_uploads ru
    where ru.created_by = p_uid and ru.is_approved = true
  ),0);

  v_has_publish := (to_regclass('rgsr.publish_submissions') is not null);

  if v_has_publish then
    v_cnt := v_cnt + coalesce((
      select count(*)
      from rgsr.publish_submissions ps
      where ps.submitted_by = p_uid and ps.status = 'approved'
    ),0);
  end if;

  return v_cnt;
end
$fn$;

commit;
