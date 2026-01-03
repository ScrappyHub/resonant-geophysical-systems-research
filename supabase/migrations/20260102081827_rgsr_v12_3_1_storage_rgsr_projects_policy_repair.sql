-- ============================================================
-- RGSR v12.3.1 — STORAGE POLICY REPAIR (NO ALTER TABLE)
-- Why:
--  - Migrations may not own storage.objects, so ALTER TABLE fails.
-- What:
--  - Keep bucket private.
--  - Drop/recreate rgsr_projects_* policies only.
-- ============================================================

begin;

-- Ensure bucket exists + private (safe)
insert into storage.buckets(id, name, public)
values ('rgsr_projects', 'rgsr_projects', false)
on conflict (id) do update set name=excluded.name, public=false;

-- Helpers (safe to create/replace in rgsr schema)
create or replace function rgsr.storage_project_id_from_name(p_name text)
returns uuid
language plpgsql
immutable
as $fn$
declare v text;
begin
  if p_name is null then return null; end if;
  if left(p_name, 9) <> 'projects/' then return null; end if;
  v := split_part(p_name, '/', 2);
  if v is null or length(v) < 36 then return null; end if;
  return v::uuid;
exception when others then
  return null;
end
$fn$;

create or replace function rgsr.storage_is_project_owner(p_project_id uuid, p_uid uuid)
returns boolean
language sql
stable
as $fn$
  select exists (
    select 1
    from rgsr.projects p
    where p.project_id = p_project_id
      and p.owner_uid = p_uid
  );
$fn$;

create or replace function rgsr.storage_project_is_public(p_project_id uuid)
returns boolean
language sql
stable
as $fn$
  select exists (
    select 1
    from rgsr.projects p
    where p.project_id = p_project_id
      and p.is_public = true
  );
$fn$;

-- Drop only our policies (avoid touching Supabase defaults)
do $do$
declare pol record;
begin
  for pol in
    select policyname
    from pg_policies
    where schemaname='storage'
      and tablename='objects'
      and policyname like 'rgsr_projects_%'
  loop
    execute format('drop policy if exists %I on storage.objects', pol.policyname);
  end loop;
end
$do$;

-- Recreate policies

create policy rgsr_projects_public_read
on storage.objects
for select
to anon, authenticated
using (
  bucket_id = 'rgsr_projects'
  and rgsr.storage_project_is_public(rgsr.storage_project_id_from_name(name))
);

create policy rgsr_projects_owner_read
on storage.objects
for select
to authenticated
using (
  bucket_id = 'rgsr_projects'
  and rgsr.storage_is_project_owner(
        rgsr.storage_project_id_from_name(name),
        auth.uid()
      )
);

create policy rgsr_projects_owner_insert
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'rgsr_projects'
  and rgsr.storage_is_project_owner(
        rgsr.storage_project_id_from_name(name),
        auth.uid()
      )
);

create policy rgsr_projects_owner_update
on storage.objects
for update
to authenticated
using (
  bucket_id = 'rgsr_projects'
  and rgsr.storage_is_project_owner(
        rgsr.storage_project_id_from_name(name),
        auth.uid()
      )
)
with check (
  bucket_id = 'rgsr_projects'
  and rgsr.storage_is_project_owner(
        rgsr.storage_project_id_from_name(name),
        auth.uid()
      )
);

create policy rgsr_projects_owner_delete
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'rgsr_projects'
  and rgsr.storage_is_project_owner(
        rgsr.storage_project_id_from_name(name),
        auth.uid()
      )
);

create policy rgsr_projects_admin_all
on storage.objects
for all
to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

commit;

-- ============================================================
-- Verify:
-- select policyname, cmd, roles
-- from pg_policies
-- where schemaname='storage' and tablename='objects'
--   and policyname like 'rgsr_projects_%'
-- order by policyname;
-- ============================================================
