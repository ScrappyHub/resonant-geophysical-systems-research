/* =====================================================================================
 CORE: Access + Entitlements + Lane + Engine Enablement + Run Contract Lock-in (V1)
 - Canonical: identity -> group -> entitlements -> lanes -> engines-on/off
 - Canonical: no run can exist without envelope + declared conditions + enabled engines
 - Enforcement: RLS + SECURITY DEFINER gates + JSON structural checks
 ===================================================================================== */

begin;

-- =====================================================================================
-- 0) Preflight introspection (safe; does not mutate)
-- =====================================================================================
do $$
begin
  raise notice 'CORE LOCK-IN V1: starting';
  raise notice 'auth.uid() available in runtime; migration runs as privileged role';
end $$;

-- =====================================================================================
-- 1) Core schema
-- =====================================================================================
create schema if not exists core;

-- =====================================================================================
-- 2) Canonical registries (DB-side mirror of your core-contracts registries)
--    NOTE: keep JSON registries in git; DB stores normalized + queryable state.
-- =====================================================================================

create table if not exists core.verticals (
  vertical_code text primary key,
  name text not null,
  description text not null default '',
  is_high_risk boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists core.engines (
  engine_code text primary key,
  name text not null,
  description text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists core.vertical_engines (
  vertical_code text not null references core.verticals(vertical_code) on delete cascade,
  engine_code text not null references core.engines(engine_code) on delete restrict,
  is_required boolean not null default false,
  primary key (vertical_code, engine_code)
);

-- =====================================================================================
-- 3) Groups, membership, lanes, entitlements
-- =====================================================================================

create table if not exists core.groups (
  group_id uuid primary key default gen_random_uuid(),
  group_slug text not null unique,
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists core.group_memberships (
  group_id uuid not null references core.groups(group_id) on delete cascade,
  user_id uuid not null, -- auth.users.id
  role text not null default 'member', -- owner/admin/member/viewer
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

-- Lanes = "capability lanes" (education-safe, research, restricted, etc.)
create table if not exists core.lanes (
  lane_code text primary key,          -- e.g. EDU_SAFE, RESEARCH, RESTRICTED, DEFENSE_LOCKED
  name text not null,
  description text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists core.group_lanes (
  group_id uuid not null references core.groups(group_id) on delete cascade,
  lane_code text not null references core.lanes(lane_code) on delete restrict,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (group_id, lane_code)
);

-- Entitlements: group can access vertical + engines (with lane constraints)
create table if not exists core.group_vertical_entitlements (
  group_id uuid not null references core.groups(group_id) on delete cascade,
  vertical_code text not null references core.verticals(vertical_code) on delete restrict,
  lane_code text null references core.lanes(lane_code) on delete restrict, -- null means any lane granted
  can_run boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (group_id, vertical_code, lane_code)
);

create table if not exists core.group_engine_entitlements (
  group_id uuid not null references core.groups(group_id) on delete cascade,
  engine_code text not null references core.engines(engine_code) on delete restrict,
  lane_code text null references core.lanes(lane_code) on delete restrict,
  is_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (group_id, engine_code, lane_code)
);

-- =====================================================================================
-- 4) Run artifacts: enforce the “Interfaces & Contracts” law
-- =====================================================================================

create table if not exists core.engine_runs (
  run_id uuid primary key default gen_random_uuid(),

  group_id uuid not null references core.groups(group_id) on delete restrict,
  vertical_code text not null references core.verticals(vertical_code) on delete restrict,

  -- "execution engine" for this run (RGSR may fuse; SIGNAL may post-process, etc.)
  primary_engine_code text not null references core.engines(engine_code) on delete restrict,

  -- Lane used at execution time (snapshotted)
  lane_code text not null references core.lanes(lane_code) on delete restrict,

  -- REQUIRED CONTRACT:
  engine_run_artifact_envelope jsonb not null,
  run_conditions jsonb not null,

  -- REQUIRED: manifest of enabled engines/versions at run time (snapshot)
  enabled_engines jsonb not null,

  -- REQUIRED: one or more result frames (versioned). Store as json array.
  result_frames jsonb not null default '[]'::jsonb,

  created_by uuid not null, -- auth.users.id
  created_at timestamptz not null default now(),

  -- Structural checks (no extension required)
  constraint engine_run_envelope_is_object check (jsonb_typeof(engine_run_artifact_envelope) = 'object'),
  constraint run_conditions_is_object check (jsonb_typeof(run_conditions) = 'object'),
  constraint enabled_engines_is_array_or_object check (jsonb_typeof(enabled_engines) in ('array','object')),
  constraint result_frames_is_array check (jsonb_typeof(result_frames) = 'array'),

  -- Minimum key requirements (contract-level)
  constraint envelope_has_required_keys check (
    (engine_run_artifact_envelope ? 'schema') and
    (engine_run_artifact_envelope ? 'run_id') and
    (engine_run_artifact_envelope ? 'vertical') and
    (engine_run_artifact_envelope ? 'primary_engine') and
    (engine_run_artifact_envelope ? 'created_at') and
    (engine_run_artifact_envelope ? 'hashes') and
    (engine_run_artifact_envelope ? 'artifacts')
  ),
  constraint conditions_has_required_keys check (
    (run_conditions ? 'declared_inputs') and
    (run_conditions ? 'assumptions') and
    (run_conditions ? 'units') and
    (run_conditions ? 'limits')
  )
);

-- Helpful indexes
create index if not exists engine_runs_group_id_idx on core.engine_runs(group_id);
create index if not exists engine_runs_vertical_idx on core.engine_runs(vertical_code);
create index if not exists engine_runs_created_at_idx on core.engine_runs(created_at desc);

-- =====================================================================================
-- 5) Canonical entitlement resolver (SECURITY DEFINER)
--    This is the “engine recognizes vertical, engines on/off, access limited between them all”
-- =====================================================================================

create or replace function core.current_user_group_id()
returns uuid
language sql
stable
as $$
  select gm.group_id
  from core.group_memberships gm
  where gm.user_id = auth.uid()
  order by gm.created_at asc
  limit 1;
$$;

create or replace function core.can_run(
  p_user_id uuid,
  p_group_id uuid,
  p_vertical_code text,
  p_primary_engine_code text,
  p_lane_code text,
  p_enabled_engines jsonb
)
returns boolean
language plpgsql
security definer
set search_path = core, public
as $$
declare
  v_is_member boolean;
  v_vertical_ok boolean;
  v_engine_ok boolean;
  v_lane_ok boolean;
begin
  -- membership
  select exists (
    select 1 from core.group_memberships
    where group_id = p_group_id and user_id = p_user_id
  ) into v_is_member;

  if not v_is_member then
    return false;
  end if;

  -- lane must be granted to group
  select exists (
    select 1 from core.group_lanes
    where group_id = p_group_id and lane_code = p_lane_code
  ) into v_lane_ok;

  if not v_lane_ok then
    return false;
  end if;

  -- vertical entitlement
  select exists (
    select 1 from core.group_vertical_entitlements
    where group_id = p_group_id
      and vertical_code = p_vertical_code
      and can_run = true
      and (lane_code is null or lane_code = p_lane_code)
  ) into v_vertical_ok;

  if not v_vertical_ok then
    return false;
  end if;

  -- primary engine entitlement
  select exists (
    select 1 from core.group_engine_entitlements
    where group_id = p_group_id
      and engine_code = p_primary_engine_code
      and is_enabled = true
      and (lane_code is null or lane_code = p_lane_code)
  ) into v_engine_ok;

  if not v_engine_ok then
    return false;
  end if;

  -- enabled_engines must not include engines the group can’t enable (best-effort structural gate)
  -- Accept either array ["MAGNETAR","THERMOS"] or object {"MAGNETAR":"1.0.0",...}
  if jsonb_typeof(p_enabled_engines) = 'array' then
    if exists (
      select 1
      from jsonb_array_elements_text(p_enabled_engines) e(engine_code)
      where not exists (
        select 1 from core.group_engine_entitlements ge
        where ge.group_id = p_group_id
          and ge.engine_code = e.engine_code
          and ge.is_enabled = true
          and (ge.lane_code is null or ge.lane_code = p_lane_code)
      )
    ) then
      return false;
    end if;
  elsif jsonb_typeof(p_enabled_engines) = 'object' then
    if exists (
      select 1
      from jsonb_object_keys(p_enabled_engines) k(engine_code)
      where not exists (
        select 1 from core.group_engine_entitlements ge
        where ge.group_id = p_group_id
          and ge.engine_code = k.engine_code
          and ge.is_enabled = true
          and (ge.lane_code is null or ge.lane_code = p_lane_code)
      )
    ) then
      return false;
    end if;
  else
    return false;
  end if;

  return true;
end;
$$;

-- =====================================================================================
-- 6) RLS: no bypass. Insert requires entitlement check.
-- =====================================================================================

alter table core.engine_runs enable row level security;

-- Read: members of group
create policy "engine_runs_read_group_members"
on core.engine_runs
for select
to authenticated
using (
  exists (
    select 1 from core.group_memberships gm
    where gm.group_id = engine_runs.group_id
      and gm.user_id = auth.uid()
  )
);

-- Insert: must pass CORE law gate
create policy "engine_runs_insert_entitled"
on core.engine_runs
for insert
to authenticated
with check (
  core.can_run(
    auth.uid(),
    engine_runs.group_id,
    engine_runs.vertical_code,
    engine_runs.primary_engine_code,
    engine_runs.lane_code,
    engine_runs.enabled_engines
  )
  and engine_runs.created_by = auth.uid()
);

-- Update/delete (optional): lock down hard by default
create policy "engine_runs_no_update"
on core.engine_runs
for update
to authenticated
using (false);

create policy "engine_runs_no_delete"
on core.engine_runs
for delete
to authenticated
using (false);

-- =====================================================================================
-- 7) Minimal seed: lanes (you can add more later)
-- =====================================================================================

insert into core.lanes(lane_code, name, description)
values
  ('EDU_SAFE', 'Education Safe', 'Simplified outputs; safety overrides depth'),
  ('RESEARCH', 'Research', 'Reproducibility-first; full metadata required'),
  ('RESTRICTED', 'Restricted', 'Higher-risk; explicit access gates required'),
  ('DEFENSE_LOCKED', 'Defense Locked', 'High-risk; tightly gated; auditable; interpretive only')
on conflict (lane_code) do nothing;

commit;
