-- ============================================================
-- RGSR v13.0 — WORLD PRIMITIVES (PROJECTS + DOMAINS + MATERIAL CATALOG)
-- Canonical: NO PII, RLS FORCED, backend-only gating
-- ============================================================

begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 0) Helpers assumed to exist:
--   - rgsr.actor_uid() -> uuid (auth uid)
--   - rgsr.can_write() -> boolean (admin gate)
-- If missing, STOP and we add them first.
-- ------------------------------------------------------------

-- ------------------------------------------------------------
-- 1) Projects (world containers)
-- ------------------------------------------------------------
create table if not exists rgsr.world_projects (
  project_id uuid primary key default gen_random_uuid(),
  owner_uid uuid not null references auth.users(id) on delete restrict,

  -- no real names; titles are optional + sanitized in app
  project_slug text not null,
  display_label text not null default '',

  -- world coordinate + units (engine uses these)
  units jsonb not null default jsonb_build_object(
    'distance', 'm',
    'time', 's',
    'mass', 'kg',
    'temperature', 'K',
    'pressure', 'Pa'
  ),

  -- world bounds / grid / resolution (2D/3D engine binds here)
  world_spec jsonb not null default jsonb_build_object(
    'mode', '3d',
    'bounds', jsonb_build_object('xmin',0,'xmax',1,'ymin',0,'ymax',1,'zmin',0,'zmax',1),
    'grid', jsonb_build_object('nx',64,'ny',64,'nz',64),
    'origin', jsonb_build_object('x',0,'y',0,'z',0)
  ),

  -- feature gates (backed by entitlements later)
  flags jsonb not null default '{}'::jsonb,

  is_public boolean not null default false,
  public_handle text null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint world_projects_slug_chk check (length(btrim(project_slug)) >= 3)
);

create unique index if not exists ux_world_projects_owner_slug
on rgsr.world_projects(owner_uid, project_slug);

create index if not exists ix_world_projects_owner_time
on rgsr.world_projects(owner_uid, created_at desc);

-- ------------------------------------------------------------
-- 2) Domains (internal regions inside a world)
--   Example: "air", "water_table", "bedrock", "cave_A", "shaft_1"
-- ------------------------------------------------------------
create table if not exists rgsr.world_domains (
  domain_id uuid primary key default gen_random_uuid(),
  project_id uuid not null references rgsr.world_projects(project_id) on delete cascade,
  owner_uid uuid not null references auth.users(id) on delete restrict,

  domain_key text not null,   -- stable id in-engine
  domain_kind text not null,  -- air/water/rock/void/custom
  label text not null default '',

  -- geometry payload for domain boundaries (engine-defined)
  geom jsonb not null default '{}'::jsonb,

  -- physical parameters for the domain (porosity, density, etc) at domain level
  params jsonb not null default '{}'::jsonb,

  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint world_domains_key_chk check (length(btrim(domain_key)) >= 2),
  constraint world_domains_kind_chk check (domain_kind in ('air','water','rock','soil','void','structure','custom'))
);

create unique index if not exists ux_world_domains_project_key
on rgsr.world_domains(project_id, domain_key);

create index if not exists ix_world_domains_project_kind
on rgsr.world_domains(project_id, domain_kind);

-- ------------------------------------------------------------
-- 3) Material catalog (owner-scoped, reusable)
--   Stores physics params but NO PII.
-- ------------------------------------------------------------
create table if not exists rgsr.material_catalog (
  material_id uuid primary key default gen_random_uuid(),
  owner_uid uuid not null references auth.users(id) on delete restrict,

  material_key text not null,     -- stable key in engine
  material_kind text not null,    -- rock/soil/water/air/structure/custom
  label text not null default '',

  params jsonb not null default '{}'::jsonb,   -- density, damping, conductivity, elasticity...
  tags text[] not null default '{}'::text[],

  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint material_key_chk check (length(btrim(material_key)) >= 2),
  constraint material_kind_chk check (material_kind in ('rock','soil','water','air','structure','custom'))
);

create unique index if not exists ux_material_catalog_owner_key
on rgsr.material_catalog(owner_uid, material_key);

-- ------------------------------------------------------------
-- 4) RLS enable + FORCE
-- ------------------------------------------------------------
alter table rgsr.world_projects enable row level security;
alter table rgsr.world_domains enable row level security;
alter table rgsr.material_catalog enable row level security;

alter table rgsr.world_projects force row level security;
alter table rgsr.world_domains force row level security;
alter table rgsr.material_catalog force row level security;

-- ------------------------------------------------------------
-- 5) Drop existing policies (avoid union leakage)
-- ------------------------------------------------------------
do $do$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname='rgsr'
      and tablename in ('world_projects','world_domains','material_catalog')
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end
$do$;

-- ------------------------------------------------------------
-- 6) Canonical policies
--   - owner: full control on own rows
--   - anon: read only public projects (minimal)
--   - admin: full via can_write()
-- ------------------------------------------------------------

-- world_projects
create policy world_projects_owner_read on rgsr.world_projects
for select to authenticated
using (owner_uid = rgsr.actor_uid());

create policy world_projects_owner_write on rgsr.world_projects
for insert to authenticated
with check (owner_uid = rgsr.actor_uid());

create policy world_projects_owner_update on rgsr.world_projects
for update to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

create policy world_projects_owner_delete on rgsr.world_projects
for delete to authenticated
using (owner_uid = rgsr.actor_uid());

create policy world_projects_public_read on rgsr.world_projects
for select to anon
using (is_public = true);

create policy world_projects_admin on rgsr.world_projects
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- world_domains
create policy world_domains_owner_rw on rgsr.world_domains
for all to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

create policy world_domains_admin on rgsr.world_domains
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- material_catalog
create policy material_catalog_owner_rw on rgsr.material_catalog
for all to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

create policy material_catalog_admin on rgsr.material_catalog
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- ------------------------------------------------------------
-- 7) Minimal grants (RLS is the gate)
-- ------------------------------------------------------------
do $do$
begin
  revoke all on schema rgsr from public;
  grant usage on schema rgsr to anon;
  grant usage on schema rgsr to authenticated;
  grant usage on schema rgsr to service_role;
end
$do$;

commit;

-- Verification (SQL):
-- select count(*) from rgsr.world_projects;
-- select count(*) from rgsr.world_domains;
-- select count(*) from rgsr.material_catalog;
-- select tablename, policyname, cmd, roles from pg_policies where schemaname='rgsr' and tablename in ('world_projects','world_domains','material_catalog') order by tablename, policyname;
