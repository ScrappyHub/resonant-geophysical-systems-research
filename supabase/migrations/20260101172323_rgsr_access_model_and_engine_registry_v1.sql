-- ============================================================
-- RGSR: Canonical Access Model + Engine Registry (V1)
-- Roles (who you are) ⟂ Plans (what you can do)
-- Lanes are immutable-forward only: PRIVATE -> LAB -> REVIEW -> PUBLISHED
-- Brand-new Supabase compatible (assumes auth.users exists).
-- ============================================================

begin;

-- 0) Extensions (safe)
create extension if not exists pgcrypto;

-- 1) Schemas
create schema if not exists rgsr;
create schema if not exists engine_registry;

-- 2) Enums
do $$
begin
  if not exists (select 1 from pg_type where typname = 'rgsr_lane') then
    create type rgsr.rgsr_lane as enum ('PRIVATE','LAB','REVIEW','PUBLISHED');
  end if;
  if not exists (select 1 from pg_type where typname = 'rgsr_role_id') then
    create type rgsr.rgsr_role_id as enum ('SYS_ADMIN','LAB_ADMIN','SCIENTIST','REVIEWER','OBSERVER');
  end if;
  if not exists (select 1 from pg_type where typname = 'rgsr_plan_id') then
    create type rgsr.rgsr_plan_id as enum ('OBSERVER_FREE','RESEARCHER_PRO','LAB_STANDARD','INSTITUTION');
  end if;
end$$;

-- 3) Identity: Role ⟂ Plan
create table if not exists rgsr.user_profiles (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  role_id        rgsr.rgsr_role_id not null default 'OBSERVER',
  plan_id        rgsr.rgsr_plan_id not null default 'OBSERVER_FREE',
  display_name   text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table if not exists rgsr.labs (
  lab_id      uuid primary key default gen_random_uuid(),
  name        text not null,
  owner_id    uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now()
);

create table if not exists rgsr.lab_members (
  lab_id      uuid not null references rgsr.labs(lab_id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  is_admin    boolean not null default false,
  created_at  timestamptz not null default now(),
  primary key (lab_id, user_id)
);

-- updated_at helper
create or replace function rgsr.tg_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_user_profiles_touch') then
    create trigger tr_user_profiles_touch
    before update on rgsr.user_profiles
    for each row execute function rgsr.tg_touch_updated_at();
  end if;
end$$;

-- 4) Capabilities + mappings
create table if not exists rgsr.capabilities (
  capability_id text primary key,
  description   text not null
);

create table if not exists rgsr.plan_capabilities (
  plan_id       rgsr.rgsr_plan_id not null,
  capability_id text not null references rgsr.capabilities(capability_id) on delete cascade,
  enabled       boolean not null default true,
  primary key (plan_id, capability_id)
);

create table if not exists rgsr.role_capabilities (
  role_id       rgsr.rgsr_role_id not null,
  capability_id text not null references rgsr.capabilities(capability_id) on delete cascade,
  enabled       boolean not null default true,
  primary key (role_id, capability_id)
);

-- 5) Review assignments
create table if not exists rgsr.review_assignments (
  experiment_id uuid not null,
  reviewer_id   uuid not null references auth.users(id) on delete cascade,
  assigned_by   uuid not null references auth.users(id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (experiment_id, reviewer_id)
);

-- 6) Experiments + forward-only lane
create table if not exists rgsr.experiments (
  experiment_id     uuid primary key default gen_random_uuid(),
  engine_code       text not null default 'RGSR',
  phase_code        text not null,
  lane              rgsr.rgsr_lane not null default 'PRIVATE',
  created_by        uuid not null references auth.users(id) on delete cascade,
  lab_id            uuid references rgsr.labs(lab_id) on delete set null,
  title             text,
  notes             text,
  conditions_profile text,
  inputs_sha256     text,
  outputs_sha256    text,
  published_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_experiments_touch') then
    create trigger tr_experiments_touch
    before update on rgsr.experiments
    for each row execute function rgsr.tg_touch_updated_at();
  end if;
end$$;

create or replace function rgsr.lane_rank(l rgsr.rgsr_lane)
returns int language sql immutable as $$
  select case l
    when 'PRIVATE' then 1
    when 'LAB' then 2
    when 'REVIEW' then 3
    when 'PUBLISHED' then 4
  end;
$$;

create or replace function rgsr.tg_enforce_lane_forward_only()
returns trigger language plpgsql as $$
begin
  if (tg_op = 'UPDATE') then
    if rgsr.lane_rank(new.lane) < rgsr.lane_rank(old.lane) then
      raise exception 'RGSR lane is forward-only: % -> % is not allowed', old.lane, new.lane
        using errcode = 'check_violation';
    end if;
    if new.lane = 'PUBLISHED' and old.lane <> 'PUBLISHED' then
      new.published_at = coalesce(new.published_at, now());
    end if;
  end if;
  return new;
end$$;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_experiments_lane_forward_only') then
    create trigger tr_experiments_lane_forward_only
    before update of lane on rgsr.experiments
    for each row execute function rgsr.tg_enforce_lane_forward_only();
  end if;
end$$;

-- 7) Condition Profiles
create table if not exists rgsr.condition_profiles (
  profile_id    uuid primary key default gen_random_uuid(),
  profile_name  text not null unique,
  profile_json  jsonb not null,
  created_by    uuid not null references auth.users(id) on delete cascade,
  created_at    timestamptz not null default now()
);

-- 8) Engine Registry
create table if not exists engine_registry.engines (
  engine_id     uuid primary key default gen_random_uuid(),
  engine_code   text not null unique,
  name          text not null,
  status        text not null default 'ACTIVE',
  version       text,
  created_at    timestamptz not null default now()
);

create table if not exists engine_registry.lanes (
  engine_code   text not null references engine_registry.engines(engine_code) on delete cascade,
  lane          rgsr.rgsr_lane not null,
  description   text not null,
  primary key (engine_code, lane)
);

create table if not exists engine_registry.engine_capabilities (
  engine_code     text not null references engine_registry.engines(engine_code) on delete cascade,
  capability_id   text not null references rgsr.capabilities(capability_id) on delete cascade,
  primary key (engine_code, capability_id)
);

-- 9) Seeds
insert into rgsr.capabilities (capability_id, description) values
  ('RUN_PHASE_A',        'Run Phase A experiments'),
  ('RUN_PHASE_B',        'Run Phase B perturbation tests'),
  ('RUN_PHASE_C',        'Run Phase C coupling tests'),
  ('RUN_PHASE_D',        'Run Phase D geometry grids'),
  ('UPLOAD_GEOMETRY',    'Upload chamber models'),
  ('DEFINE_CONDITIONS',  'Create condition profiles'),
  ('EXPORT_RAW',         'Download raw data'),
  ('PUBLISH',            'Move to PUBLISHED lane'),
  ('REQUEST_REVIEW',     'Submit to reviewers'),
  ('VIEW_PUBLISHED',     'See public results'),
  ('TEAM_SHARE',         'Share inside a lab'),
  ('API_ACCESS',         'Programmatic access'),
  ('REVIEWER_ASSIGNMENT','Assign/manage reviewers')
on conflict do nothing;

-- OBSERVER_FREE
insert into rgsr.plan_capabilities(plan_id, capability_id, enabled) values
  ('OBSERVER_FREE','VIEW_PUBLISHED', true)
on conflict do nothing;

-- RESEARCHER_PRO
insert into rgsr.plan_capabilities(plan_id, capability_id, enabled) values
  ('RESEARCHER_PRO','RUN_PHASE_A', true),
  ('RESEARCHER_PRO','UPLOAD_GEOMETRY', true),
  ('RESEARCHER_PRO','DEFINE_CONDITIONS', true),
  ('RESEARCHER_PRO','EXPORT_RAW', true),
  ('RESEARCHER_PRO','VIEW_PUBLISHED', true)
on conflict do nothing;

-- LAB_STANDARD
insert into rgsr.plan_capabilities(plan_id, capability_id, enabled) values
  ('LAB_STANDARD','RUN_PHASE_A', true),
  ('LAB_STANDARD','RUN_PHASE_B', true),
  ('LAB_STANDARD','TEAM_SHARE', true),
  ('LAB_STANDARD','REQUEST_REVIEW', true),
  ('LAB_STANDARD','EXPORT_RAW', true),
  ('LAB_STANDARD','DEFINE_CONDITIONS', true),
  ('LAB_STANDARD','UPLOAD_GEOMETRY', true),
  ('LAB_STANDARD','VIEW_PUBLISHED', true)
on conflict do nothing;

-- INSTITUTION
insert into rgsr.plan_capabilities(plan_id, capability_id, enabled) values
  ('INSTITUTION','RUN_PHASE_A', true),
  ('INSTITUTION','RUN_PHASE_B', true),
  ('INSTITUTION','RUN_PHASE_C', true),
  ('INSTITUTION','RUN_PHASE_D', true),
  ('INSTITUTION','PUBLISH', true),
  ('INSTITUTION','API_ACCESS', true),
  ('INSTITUTION','REVIEWER_ASSIGNMENT', true),
  ('INSTITUTION','REQUEST_REVIEW', true),
  ('INSTITUTION','EXPORT_RAW', true),
  ('INSTITUTION','DEFINE_CONDITIONS', true),
  ('INSTITUTION','UPLOAD_GEOMETRY', true),
  ('INSTITUTION','VIEW_PUBLISHED', true),
  ('INSTITUTION','TEAM_SHARE', true)
on conflict do nothing;

-- SYS_ADMIN gets everything
insert into rgsr.role_capabilities(role_id, capability_id, enabled)
select 'SYS_ADMIN'::rgsr.rgsr_role_id, c.capability_id, true
from rgsr.capabilities c
on conflict do nothing;

-- Engine registry seed
insert into engine_registry.engines(engine_code, name, status, version)
values ('RGSR','Resonant Geophysical Systems Research','ACTIVE','V1')
on conflict (engine_code) do nothing;

insert into engine_registry.lanes(engine_code, lane, description) values
  ('RGSR','PRIVATE','Only the creator can see it'),
  ('RGSR','LAB','Visible to your lab/team'),
  ('RGSR','REVIEW','Visible to assigned reviewers'),
  ('RGSR','PUBLISHED','Public & immutable')
on conflict do nothing;

insert into engine_registry.engine_capabilities(engine_code, capability_id)
select 'RGSR', capability_id from rgsr.capabilities
on conflict do nothing;

-- 10) Helper functions for RLS
create or replace function rgsr.current_role()
returns rgsr.rgsr_role_id
language sql stable as $$
  select coalesce((select up.role_id from rgsr.user_profiles up where up.user_id = auth.uid()),
                  'OBSERVER'::rgsr.rgsr_role_id);
$$;

create or replace function rgsr.current_plan()
returns rgsr.rgsr_plan_id
language sql stable as $$
  select coalesce((select up.plan_id from rgsr.user_profiles up where up.user_id = auth.uid()),
                  'OBSERVER_FREE'::rgsr.rgsr_plan_id);
$$;

create or replace function rgsr.has_capability(cap text)
returns boolean
language sql stable as $$
  with me as (select rgsr.current_role() as role_id, rgsr.current_plan() as plan_id)
  select exists (
    select 1 from me
    join rgsr.plan_capabilities pc on pc.plan_id = me.plan_id
    where pc.capability_id = cap and pc.enabled
  )
  or exists (
    select 1 from me
    join rgsr.role_capabilities rc on rc.role_id = me.role_id
    where rc.capability_id = cap and rc.enabled
  );
$$;

create or replace function rgsr.is_sys_admin()
returns boolean
language sql stable as $$
  select rgsr.current_role() = 'SYS_ADMIN'::rgsr.rgsr_role_id;
$$;

create or replace function rgsr.is_lab_member(lab uuid)
returns boolean
language sql stable as $$
  select exists (select 1 from rgsr.lab_members lm where lm.lab_id = lab and lm.user_id = auth.uid())
     or exists (select 1 from rgsr.labs l where l.lab_id = lab and l.owner_id = auth.uid());
$$;

create or replace function rgsr.is_assigned_reviewer(experiment uuid)
returns boolean
language sql stable as $$
  select exists (select 1 from rgsr.review_assignments ra where ra.experiment_id = experiment and ra.reviewer_id = auth.uid());
$$;

create or replace function rgsr.can_read_lane(l rgsr.rgsr_lane, created_by uuid, lab uuid, experiment uuid)
returns boolean
language sql stable as $$
  select (rgsr.is_sys_admin())
  or case l
       when 'PUBLISHED' then true
       when 'PRIVATE' then (auth.uid() = created_by) and rgsr.has_capability('RUN_PHASE_A')
       when 'LAB' then rgsr.is_lab_member(lab) and rgsr.has_capability('TEAM_SHARE')
       when 'REVIEW' then (
         (rgsr.is_assigned_reviewer(experiment) and rgsr.current_role() in ('REVIEWER','SYS_ADMIN'))
         or (rgsr.is_lab_member(lab) and rgsr.has_capability('REQUEST_REVIEW'))
       )
     end;
$$;

create or replace function rgsr.can_write_lane_target(new_lane rgsr.rgsr_lane)
returns boolean
language sql stable as $$
  select rgsr.is_sys_admin()
  or case new_lane
       when 'PRIVATE' then true
       when 'LAB' then rgsr.has_capability('TEAM_SHARE')
       when 'REVIEW' then rgsr.has_capability('REQUEST_REVIEW')
       when 'PUBLISHED' then rgsr.has_capability('PUBLISH')
     end;
$$;

-- 11) RLS enable + policies
alter table rgsr.user_profiles enable row level security;
alter table rgsr.labs enable row level security;
alter table rgsr.lab_members enable row level security;
alter table rgsr.experiments enable row level security;
alter table rgsr.review_assignments enable row level security;
alter table rgsr.condition_profiles enable row level security;

-- user_profiles
drop policy if exists up_select on rgsr.user_profiles;
create policy up_select on rgsr.user_profiles for select to authenticated
using (user_id = auth.uid() or rgsr.is_sys_admin());

drop policy if exists up_insert on rgsr.user_profiles;
create policy up_insert on rgsr.user_profiles for insert to authenticated
with check (user_id = auth.uid() or rgsr.is_sys_admin());

drop policy if exists up_update on rgsr.user_profiles;
create policy up_update on rgsr.user_profiles for update to authenticated
using (user_id = auth.uid() or rgsr.is_sys_admin())
with check (user_id = auth.uid() or rgsr.is_sys_admin());

-- labs
drop policy if exists labs_select on rgsr.labs;
create policy labs_select on rgsr.labs for select to authenticated
using (
  rgsr.is_sys_admin()
  or owner_id = auth.uid()
  or exists (select 1 from rgsr.lab_members lm where lm.lab_id = lab_id and lm.user_id = auth.uid())
);

drop policy if exists labs_insert on rgsr.labs;
create policy labs_insert on rgsr.labs for insert to authenticated
with check (owner_id = auth.uid() or rgsr.is_sys_admin());

drop policy if exists labs_update on rgsr.labs;
create policy labs_update on rgsr.labs for update to authenticated
using (owner_id = auth.uid() or rgsr.is_sys_admin())
with check (owner_id = auth.uid() or rgsr.is_sys_admin());

-- lab_members
drop policy if exists lm_select on rgsr.lab_members;
create policy lm_select on rgsr.lab_members for select to authenticated
using (
  rgsr.is_sys_admin()
  or exists (select 1 from rgsr.labs l where l.lab_id = lab_id and l.owner_id = auth.uid())
  or user_id = auth.uid()
);

drop policy if exists lm_insert on rgsr.lab_members;
create policy lm_insert on rgsr.lab_members for insert to authenticated
with check (
  rgsr.is_sys_admin()
  or exists (select 1 from rgsr.labs l where l.lab_id = lab_id and l.owner_id = auth.uid())
);

drop policy if exists lm_delete on rgsr.lab_members;
create policy lm_delete on rgsr.lab_members for delete to authenticated
using (
  rgsr.is_sys_admin()
  or exists (select 1 from rgsr.labs l where l.lab_id = lab_id and l.owner_id = auth.uid())
);

-- experiments
drop policy if exists exp_select on rgsr.experiments;
create policy exp_select on rgsr.experiments for select to authenticated
using (rgsr.can_read_lane(lane, created_by, lab_id, experiment_id));

drop policy if exists exp_insert on rgsr.experiments;
create policy exp_insert on rgsr.experiments for insert to authenticated
with check (
  created_by = auth.uid()
  and rgsr.can_write_lane_target(lane)
  and (
    (phase_code = 'PHASE_A' and rgsr.has_capability('RUN_PHASE_A'))
    or (phase_code = 'PHASE_B' and rgsr.has_capability('RUN_PHASE_B'))
    or (phase_code = 'PHASE_C' and rgsr.has_capability('RUN_PHASE_C'))
    or (phase_code = 'PHASE_D' and rgsr.has_capability('RUN_PHASE_D'))
  )
  and (lab_id is null or rgsr.is_lab_member(lab_id))
);

drop policy if exists exp_update on rgsr.experiments;
create policy exp_update on rgsr.experiments for update to authenticated
using (
  rgsr.is_sys_admin()
  or created_by = auth.uid()
  or (lab_id is not null and rgsr.is_lab_member(lab_id))
)
with check (
  rgsr.can_write_lane_target(lane)
  and (lab_id is null or rgsr.is_lab_member(lab_id))
);

-- review_assignments
drop policy if exists ra_select on rgsr.review_assignments;
create policy ra_select on rgsr.review_assignments for select to authenticated
using (rgsr.is_sys_admin() or reviewer_id = auth.uid() or assigned_by = auth.uid());

drop policy if exists ra_insert on rgsr.review_assignments;
create policy ra_insert on rgsr.review_assignments for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.has_capability('REVIEWER_ASSIGNMENT'));

drop policy if exists ra_delete on rgsr.review_assignments;
create policy ra_delete on rgsr.review_assignments for delete to authenticated
using (rgsr.is_sys_admin() or rgsr.has_capability('REVIEWER_ASSIGNMENT'));

-- condition_profiles
drop policy if exists cp_select on rgsr.condition_profiles;
create policy cp_select on rgsr.condition_profiles for select to authenticated
using (true);

drop policy if exists cp_insert on rgsr.condition_profiles;
create policy cp_insert on rgsr.condition_profiles for insert to authenticated
with check (created_by = auth.uid() and rgsr.has_capability('DEFINE_CONDITIONS'));

-- 12) Auto-provision user_profiles on signup
create or replace function rgsr.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
begin
  insert into rgsr.user_profiles (user_id, role_id, plan_id, display_name)
  values (new.id, 'OBSERVER', 'OBSERVER_FREE', coalesce(new.email, new.phone))
  on conflict (user_id) do nothing;
  return new;
end;
$$;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_rgsr_on_auth_user_created') then
    create trigger tr_rgsr_on_auth_user_created
    after insert on auth.users
    for each row execute function rgsr.handle_new_user();
  end if;
end$$;

commit;

-- ============================================================
-- End migration
-- ============================================================
