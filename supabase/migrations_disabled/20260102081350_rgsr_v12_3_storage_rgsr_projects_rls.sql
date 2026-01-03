-- ============================================================
-- RGSR v12.3 — STORAGE RLS (rgsr_projects bucket)
-- Goals:
--  - Private by default (no anon listing)
--  - Owner can read/write objects under: projects/<project_id>/...
--  - Public read ONLY if:
--      * project.is_public = true
--      * AND object path is under that project prefix
--  - Admin override via rgsr.can_write()
-- Notes:
--  - No PII stored; identity handled separately
--  - Uses auth.uid() for storage policies
-- ============================================================

begin;

-- Guard: storage schema must exist in Supabase
do $do$
begin
  if not exists (select 1 from pg_namespace where nspname='storage') then
    raise exception 'storage schema not found (Supabase Storage not enabled?)';
  end if;
end
$do$;

-- Ensure bucket exists + private
insert into storage.buckets(id, name, public)
values ('rgsr_projects', 'rgsr_projects', false)
on conflict (id) do update set name=excluded.name, public=false;

-- ------------------------------------------------------------
-- Helper: derive project_id from object name prefix
-- Expected: projects/<uuid>/...
-- ------------------------------------------------------------
create or replace function rgsr.storage_project_id_from_name(p_name text)
returns uuid
language plpgsql
immutable
as $fn$
declare
  v text;
begin
  -- quick guard
  if p_name is null then return null; end if;

  -- must start with 'projects/'
  if left(p_name, 9) <> 'projects/' then
    return null;
  end if;

  -- extract second segment (uuid)
  v := split_part(p_name, '/', 2);
  if v is null or length(v) < 36 then
    return null;
  end if;

  return v::uuid;
exception when others then
  return null;
end
$fn$;

-- ------------------------------------------------------------
-- Helper: check ownership of project
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- Helper: check project is public
-- ------------------------------------------------------------
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

-- ------------------------------------------------------------
-- Enable RLS on storage.objects (normally already enabled)
-- ------------------------------------------------------------
alter table storage.objects enable row level security;
alter table storage.objects force row level security;

-- Drop existing policies that could leak (only for this bucket)
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

-- ------------------------------------------------------------
-- Policies
-- ------------------------------------------------------------

-- 1) Public read (anon/auth) ONLY for published projects
create policy rgsr_projects_public_read
on storage.objects
for select
to anon, authenticated
using (
  bucket_id = 'rgsr_projects'
  and rgsr.storage_project_is_public(rgsr.storage_project_id_from_name(name))
);

-- 2) Owner read (authenticated)
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

-- 3) Owner write (insert)
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

-- 4) Owner write (update)
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

-- 5) Owner delete
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

-- 6) Admin override (authenticated) — full control
create policy rgsr_projects_admin_all
on storage.objects
for all
to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

commit;

-- ============================================================
-- Expected object naming:
--   projects/<project_id>/<anything>
-- Example:
--   projects/11111111-1111-1111-1111-111111111111/state.json
-- ============================================================
