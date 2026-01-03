-- ============================================================
-- RGSR v10.1 FIX: Labs/Lane/Runs/Measurements/Artifacts (NO LEAKAGE)
-- - Normalizes existing rgsr.labs / rgsr.lab_members if they exist
-- - Ensures columns exist BEFORE functions/policies reference them
-- - Strict lane-gated RLS; child tables inherit visibility via parent run
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 0) Base governance helpers (safe to define early)
-- ------------------------------------------------------------
create or replace function rgsr.is_sys_admin()
returns boolean
language sql stable as $sql$
  select coalesce((select (auth.jwt() -> 'app_metadata' ->> 'role') = 'sys_admin'), false);
$sql$;

create or replace function rgsr.is_service_role()
returns boolean
language sql stable as $sql$
  select coalesce((select (auth.jwt() ->> 'role') = 'service_role'), false);
$sql$;

create or replace function rgsr.me()
returns uuid
language sql stable as $sql$
  select auth.uid();
$sql$;

-- ------------------------------------------------------------
-- 1) Labs + membership tables (create or normalize)
-- ------------------------------------------------------------
create table if not exists rgsr.labs (
  lab_id uuid primary key default gen_random_uuid(),
  lane text not null default 'LAB',
  lab_code text not null unique,
  display_name text not null,
  description text null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint labs_lane_chk check (lane in ('LAB','INTERNAL'))
);
create index if not exists ix_labs_code on rgsr.labs(lab_code);

create table if not exists rgsr.lab_members (
  membership_id uuid primary key default gen_random_uuid(),
  lab_id uuid not null references rgsr.labs(lab_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  member_role text not null default 'MEMBER',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lab_members_role_chk check (member_role in ('OWNER','ADMIN','MEMBER','VIEWER')),
  constraint lab_members_unique unique (lab_id, user_id)
);
create index if not exists ix_lab_members_lab on rgsr.lab_members(lab_id);
create index if not exists ix_lab_members_user on rgsr.lab_members(user_id);

-- Normalize older lab_members if it existed without these columns/constraints
do $do$
begin
  -- add member_role if missing
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='lab_members')
     and not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='member_role') then
    execute 'alter table rgsr.lab_members add column member_role text not null default ''MEMBER''';
  end if;

  -- add is_active if missing
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='lab_members')
     and not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='is_active') then
    execute 'alter table rgsr.lab_members add column is_active boolean not null default true';
  end if;

  -- add created_at/updated_at if missing
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='lab_members')
     and not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='created_at') then
    execute 'alter table rgsr.lab_members add column created_at timestamptz not null default now()';
  end if;
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='lab_members')
     and not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='updated_at') then
    execute 'alter table rgsr.lab_members add column updated_at timestamptz not null default now()';
  end if;

  -- ensure unique(lab_id,user_id)
  begin
    execute 'alter table rgsr.lab_members add constraint lab_members_unique unique (lab_id, user_id)';
  exception when duplicate_object then null;
  end;

  -- ensure role check constraint
  begin
    execute 'alter table rgsr.lab_members add constraint lab_members_role_chk check (member_role in (''OWNER'',''ADMIN'',''MEMBER'',''VIEWER''))';
  exception when duplicate_object then null;
  end;
end
$do$;

-- ------------------------------------------------------------
-- 2) Lane gates (NOW SAFE: lab_members has is_active)
-- ------------------------------------------------------------
create or replace function rgsr.has_lab_access(p_lab_id uuid)
returns boolean
language sql stable as $sql$
  select
    rgsr.is_sys_admin() or rgsr.is_service_role()
    or (p_lab_id is not null and exists (
      select 1 from rgsr.lab_members m
      where m.lab_id = p_lab_id and m.user_id = rgsr.me() and m.is_active = true
    ));
$sql$;

create or replace function rgsr.can_read_lane(p_lane text, p_lab_id uuid)
returns boolean
language sql stable as $sql$
  select
    case
      when p_lane = 'PUBLIC' then (rgsr.me() is not null)
      when p_lane = 'LAB' then rgsr.has_lab_access(p_lab_id)
      when p_lane = 'INTERNAL' then (rgsr.is_sys_admin() or rgsr.is_service_role())
      else false
    end;
$sql$;

create or replace function rgsr.can_write()
returns boolean
language sql stable as $sql$
  select (rgsr.is_sys_admin() or rgsr.is_service_role());
$sql$;

-- ------------------------------------------------------------
-- 3) Runs + Measurements + Artifacts
-- ------------------------------------------------------------
create table if not exists rgsr.runs (
  run_id uuid primary key default gen_random_uuid(),
  lane text not null default 'LAB',
  lab_id uuid null references rgsr.labs(lab_id) on delete set null,
  status text not null default 'PLANNED',
  run_code text null unique,
  title text null,
  purpose text null,
  started_at timestamptz null,
  ended_at timestamptz null,
  container_material_id uuid null,
  chamber_structure_id uuid null,
  substrate_structure_id uuid null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  constraint runs_lane_chk check (lane in ('PUBLIC','LAB','INTERNAL')),
  constraint runs_status_chk check (status in ('PLANNED','ACTIVE','COMPLETE','ABORTED')),
  constraint runs_time_chk check (ended_at is null or started_at is null or ended_at >= started_at)
);
create index if not exists ix_runs_lane on rgsr.runs(lane);
create index if not exists ix_runs_lab on rgsr.runs(lab_id);
create index if not exists ix_runs_status on rgsr.runs(status);
create index if not exists ix_runs_created_at on rgsr.runs(created_at);

create table if not exists rgsr.run_measurements (
  measurement_id uuid primary key default gen_random_uuid(),
  run_id uuid not null references rgsr.runs(run_id) on delete cascade,
  measured_at timestamptz not null default now(),
  domain text not null,
  metric_key text not null,
  unit text null,
  value_num numeric null,
  value_text text null,
  value_json jsonb null,
  quality_flags jsonb not null default '{}'::jsonb,
  source_instrument jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint rm_domain_chk check (domain in ('WATER','EM','THERMAL','ACOUSTIC','CHEM','PRESSURE','OTHER')),
  constraint rm_metric_chk check (length(metric_key) > 0),
  constraint rm_one_value_chk check (
    (case when value_num  is null then 0 else 1 end) +
    (case when value_text is null then 0 else 1 end) +
    (case when value_json is null then 0 else 1 end)
    = 1
  )
);
create index if not exists ix_rm_run on rgsr.run_measurements(run_id);
create index if not exists ix_rm_measured_at on rgsr.run_measurements(measured_at);
create index if not exists ix_rm_domain_metric on rgsr.run_measurements(domain, metric_key);

create table if not exists rgsr.run_artifacts (
  artifact_id uuid primary key default gen_random_uuid(),
  run_id uuid not null references rgsr.runs(run_id) on delete cascade,
  artifact_kind text not null,
  artifact_uri text not null,
  artifact_hash text null,
  content_type text null,
  byte_size bigint null,
  created_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  constraint ra_kind_chk check (artifact_kind in ('SPECTRUM','LOG','CSV','IMAGE','VIDEO','OTHER')),
  constraint ra_uri_chk check (length(artifact_uri) > 0)
);
create index if not exists ix_ra_run on rgsr.run_artifacts(run_id);
create index if not exists ix_ra_kind on rgsr.run_artifacts(artifact_kind);
create index if not exists ix_ra_created_at on rgsr.run_artifacts(created_at);

-- ------------------------------------------------------------
-- 4) Optional FK attachments (introspection; no assumptions)
-- ------------------------------------------------------------
do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='run_conditions') then
    begin
      execute 'alter table rgsr.run_conditions
               add constraint fk_run_conditions_run_v10_1
               foreign key (run_id) references rgsr.runs(run_id) on delete set null';
    exception when duplicate_object then null;
    end;
  end if;

  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='material_profiles') then
    begin
      execute 'alter table rgsr.runs
               add constraint fk_runs_container_material_v10_1
               foreign key (container_material_id) references rgsr.material_profiles(material_id) on delete set null';
    exception when duplicate_object then null;
    end;
  end if;

  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='geology_structures') then
    begin
      execute 'alter table rgsr.runs
               add constraint fk_runs_chamber_structure_v10_1
               foreign key (chamber_structure_id) references rgsr.geology_structures(structure_id) on delete set null';
    exception when duplicate_object then null;
    end;
    begin
      execute 'alter table rgsr.runs
               add constraint fk_runs_substrate_structure_v10_1
               foreign key (substrate_structure_id) references rgsr.geology_structures(structure_id) on delete set null';
    exception when duplicate_object then null;
    end;
  end if;
end
$do$;

-- ------------------------------------------------------------
-- 5) RLS: STRICT lane gating (no leakage)
-- ------------------------------------------------------------
alter table rgsr.labs enable row level security;
alter table rgsr.lab_members enable row level security;
alter table rgsr.runs enable row level security;
alter table rgsr.run_measurements enable row level security;
alter table rgsr.run_artifacts enable row level security;

-- labs: read limited; write governed
drop policy if exists labs_select on rgsr.labs;
create policy labs_select on rgsr.labs for select to authenticated
using (
  (rgsr.can_read_lane(lane, lab_id))
  or exists (select 1 from rgsr.lab_members m where m.lab_id = labs.lab_id and m.user_id = rgsr.me() and m.is_active = true)
);

drop policy if exists labs_write on rgsr.labs;
create policy labs_write on rgsr.labs for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- memberships: users can see their own row; write governed
drop policy if exists lm_select on rgsr.lab_members;
create policy lm_select on rgsr.lab_members for select to authenticated
using (user_id = rgsr.me() or rgsr.can_write());

drop policy if exists lm_write on rgsr.lab_members;
create policy lm_write on rgsr.lab_members for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- runs: lane read; write governed
drop policy if exists runs_select on rgsr.runs;
create policy runs_select on rgsr.runs for select to authenticated
using (rgsr.can_read_lane(lane, lab_id));

drop policy if exists runs_write on rgsr.runs;
create policy runs_write on rgsr.runs for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- measurements: inherit run visibility
drop policy if exists rm_select on rgsr.run_measurements;
create policy rm_select on rgsr.run_measurements for select to authenticated
using (exists (select 1 from rgsr.runs r where r.run_id = run_measurements.run_id and rgsr.can_read_lane(r.lane, r.lab_id)));

drop policy if exists rm_write on rgsr.run_measurements;
create policy rm_write on rgsr.run_measurements for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- artifacts: inherit run visibility
drop policy if exists ra_select on rgsr.run_artifacts;
create policy ra_select on rgsr.run_artifacts for select to authenticated
using (exists (select 1 from rgsr.runs r where r.run_id = run_artifacts.run_id and rgsr.can_read_lane(r.lane, r.lab_id)));

drop policy if exists ra_write on rgsr.run_artifacts;
create policy ra_write on rgsr.run_artifacts for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

commit;
-- ============================================================
-- End migration
-- ============================================================
