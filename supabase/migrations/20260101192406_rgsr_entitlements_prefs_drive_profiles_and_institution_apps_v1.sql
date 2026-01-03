-- ============================================================
-- RGSR: Entitlements + Preferences (C/F) + Drive Profiles + Institution Apps
--      + Fix get_lab_team() + Password policy core
-- ============================================================

begin;

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 0) Helper: service role detection (canonical for secure automation)
-- ------------------------------------------------------------
create or replace function rgsr.is_service_role()
returns boolean
language sql stable as $$
  select coalesce(auth.role() = 'service_role', false);
$$;

-- ------------------------------------------------------------
-- 1) FIX: get_lab_team() syntax error (the prior migration failed here)
-- ------------------------------------------------------------
create or replace function rgsr.get_lab_team(p_lab uuid)
returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'lab_id', p_lab,
    'members', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'user_id', up.user_id,
          'display_name', up.display_name,
          'plan_id', up.plan_id,
          'role_id', up.role_id,
          'seat_role', lm.seat_role,
          'is_owner', (l.owner_id = up.user_id)
        )
        order by (l.owner_id = up.user_id) desc, lm.created_at asc
      )
      from rgsr.labs l
      join rgsr.lab_members lm on lm.lab_id = l.lab_id
      join rgsr.user_profiles up on up.user_id = lm.user_id
      where l.lab_id = p_lab
        and rgsr.is_lab_member(p_lab)
        and rgsr.me_has_lab_capability(p_lab, 'TEAM_ROSTER_VIEW')
    ), '[]'::jsonb)
  );
$$;

-- ------------------------------------------------------------
-- 2) User Preferences: Celsius / Fahrenheit (profile-level setting)
-- ------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
                 where n.nspname='rgsr' and t.typname='temp_unit') then
    create type rgsr.temp_unit as enum ('C','F');
  end if;
end $$;

create table if not exists rgsr.user_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  temp_unit rgsr.temp_unit not null default 'C',
  ui_prefs jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_user_preferences_touch') then
    create trigger tr_user_preferences_touch
    before update on rgsr.user_preferences
    for each row execute function rgsr.tg_touch_updated_at();
  end if;
end$$;

alter table rgsr.user_preferences enable row level security;

drop policy if exists upref_select on rgsr.user_preferences;
create policy upref_select on rgsr.user_preferences for select to authenticated
using (rgsr.is_sys_admin() or user_id = auth.uid());

drop policy if exists upref_insert on rgsr.user_preferences;
create policy upref_insert on rgsr.user_preferences for insert to authenticated
with check (user_id = auth.uid());

drop policy if exists upref_update on rgsr.user_preferences;
create policy upref_update on rgsr.user_preferences for update to authenticated
using (rgsr.is_sys_admin() or user_id = auth.uid())
with check (rgsr.is_sys_admin() or user_id = auth.uid());

create or replace function rgsr.get_my_preferences()
returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'user_id', auth.uid(),
    'temp_unit', coalesce((select p.temp_unit::text from rgsr.user_preferences p where p.user_id = auth.uid()), 'C'),
    'ui_prefs', coalesce((select p.ui_prefs from rgsr.user_preferences p where p.user_id = auth.uid()), '{}'::jsonb)
  );
$$;

create or replace function rgsr.set_my_preferences(p_temp_unit text, p_ui_prefs jsonb default null)
returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
begin
  if p_temp_unit is null or p_temp_unit not in ('C','F') then
    raise exception 'invalid temp unit' using errcode = 'invalid_parameter_value';
  end if;

  insert into rgsr.user_preferences(user_id, temp_unit, ui_prefs)
  values (auth.uid(), p_temp_unit::rgsr.temp_unit, coalesce(p_ui_prefs, '{}'::jsonb))
  on conflict (user_id) do update
    set temp_unit = excluded.temp_unit,
        ui_prefs = case when p_ui_prefs is null then rgsr.user_preferences.ui_prefs else excluded.ui_prefs end,
        updated_at = now();
end;
$$;

revoke all on function rgsr.set_my_preferences(text, jsonb) from public;
grant execute on function rgsr.get_my_preferences() to authenticated;
grant execute on function rgsr.set_my_preferences(text, jsonb) to authenticated;

-- ------------------------------------------------------------
-- 3) Enriched Drive Controls: Drive Profiles (lane-aware, template-capable)
--    This is the canonical, extensible model behind the screenshot controls.
-- ------------------------------------------------------------
insert into rgsr.capabilities (capability_id, description) values
  ('DRIVE_PROFILE_VIEW',      'View drive control profiles (private + lab + published)'),
  ('DRIVE_PROFILE_CREATE',    'Create private drive control profiles'),
  ('DRIVE_PROFILE_EDIT',      'Edit drive profiles you own (or lab-permitted)'),
  ('DRIVE_PROFILE_SHARE_LAB', 'Share drive profiles into LAB lane'),
  ('DRIVE_PROFILE_TEMPLATE',  'Mark drive profiles as templates'),
  ('DRIVE_PROFILE_PUBLISH',   'Publish drive templates (PUBLISHED lane)')
on conflict do nothing;

-- baseline: authenticated can view templates
insert into rgsr.plan_capabilities(plan_id, capability_id, enabled) values
  ('OBSERVER_FREE','DRIVE_PROFILE_VIEW', true),
  ('RESEARCHER_PRO','DRIVE_PROFILE_VIEW', true),
  ('LAB_STANDARD','DRIVE_PROFILE_VIEW', true),
  ('INSTITUTION','DRIVE_PROFILE_VIEW', true)
on conflict do nothing;

-- creation/edit: researcher+
insert into rgsr.plan_capabilities(plan_id, capability_id, enabled) values
  ('RESEARCHER_PRO','DRIVE_PROFILE_CREATE', true),
  ('RESEARCHER_PRO','DRIVE_PROFILE_EDIT', true),
  ('LAB_STANDARD','DRIVE_PROFILE_CREATE', true),
  ('LAB_STANDARD','DRIVE_PROFILE_EDIT', true),
  ('LAB_STANDARD','DRIVE_PROFILE_SHARE_LAB', true),
  ('INSTITUTION','DRIVE_PROFILE_CREATE', true),
  ('INSTITUTION','DRIVE_PROFILE_EDIT', true),
  ('INSTITUTION','DRIVE_PROFILE_SHARE_LAB', true),
  ('INSTITUTION','DRIVE_PROFILE_TEMPLATE', true),
  ('INSTITUTION','DRIVE_PROFILE_PUBLISH', true)
on conflict do nothing;

create table if not exists rgsr.drive_profiles (
  drive_profile_id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  lane rgsr.rgsr_lane not null default 'PRIVATE',
  is_template boolean not null default false,
  engine_code text not null default 'RGSR',
  owner_id uuid not null references auth.users(id) on delete cascade,
  lab_id uuid references rgsr.labs(lab_id) on delete set null,
  drive_json jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'drive_profiles_engine_name_lane_tpl_uq') then
    alter table rgsr.drive_profiles add constraint drive_profiles_engine_name_lane_tpl_uq unique (engine_code, name, lane, is_template);
  end if;
end$$;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_drive_profiles_touch') then
    create trigger tr_drive_profiles_touch
    before update on rgsr.drive_profiles
    for each row execute function rgsr.tg_touch_updated_at();
  end if;
end$$;

create or replace function rgsr.tg_drive_lane_forward_only()
returns trigger language plpgsql as $$
begin
  if (tg_op = 'UPDATE') then
    if rgsr.lane_rank(new.lane) < rgsr.lane_rank(old.lane) then
      raise exception 'Drive profile lane is forward-only: % -> % is not allowed', old.lane, new.lane
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end$$;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_drive_lane_forward_only') then
    create trigger tr_drive_lane_forward_only
    before update of lane on rgsr.drive_profiles
    for each row execute function rgsr.tg_drive_lane_forward_only();
  end if;
end$$;

create or replace function rgsr.can_read_drive_profile(p_lane rgsr.rgsr_lane, p_owner uuid, p_lab uuid)
returns boolean
language sql stable as $$
  select rgsr.is_sys_admin()
  or case p_lane
    when 'PUBLISHED' then true
    when 'PRIVATE' then (auth.uid() = p_owner) and rgsr.has_capability('DRIVE_PROFILE_VIEW')
    when 'LAB' then (p_lab is not null and rgsr.is_lab_member(p_lab) and rgsr.has_capability('DRIVE_PROFILE_VIEW'))
    when 'REVIEW' then (p_lab is not null and rgsr.is_lab_member(p_lab) and rgsr.has_capability('DRIVE_PROFILE_VIEW'))
  end;
$$;

create or replace function rgsr.can_write_drive_profile_target(p_lane rgsr.rgsr_lane, p_lab uuid)
returns boolean
language sql stable as $$
  select rgsr.is_sys_admin()
  or case p_lane
    when 'PRIVATE' then rgsr.has_capability('DRIVE_PROFILE_CREATE')
    when 'LAB' then (p_lab is not null and rgsr.me_has_lab_capability(p_lab, 'DRIVE_PROFILE_SHARE_LAB') and rgsr.has_capability('DRIVE_PROFILE_CREATE'))
    when 'REVIEW' then (p_lab is not null and rgsr.me_has_lab_capability(p_lab, 'DRIVE_PROFILE_SHARE_LAB') and rgsr.has_capability('DRIVE_PROFILE_CREATE'))
    when 'PUBLISHED' then rgsr.has_capability('DRIVE_PROFILE_PUBLISH')
  end;
$$;

alter table rgsr.drive_profiles enable row level security;

drop policy if exists dp_select on rgsr.drive_profiles;
create policy dp_select on rgsr.drive_profiles for select to authenticated
using (rgsr.can_read_drive_profile(lane, owner_id, lab_id));

drop policy if exists dp_insert on rgsr.drive_profiles;
create policy dp_insert on rgsr.drive_profiles for insert to authenticated
with check (
  owner_id = auth.uid()
  and rgsr.can_write_drive_profile_target(lane, lab_id)
  and (lab_id is null or rgsr.is_lab_member(lab_id))
);

drop policy if exists dp_update on rgsr.drive_profiles;
create policy dp_update on rgsr.drive_profiles for update to authenticated
using (
  rgsr.is_sys_admin()
  or owner_id = auth.uid()
  or (lab_id is not null and rgsr.me_has_lab_capability(lab_id, 'DRIVE_PROFILE_EDIT'))
)
with check (
  rgsr.can_write_drive_profile_target(lane, lab_id)
  and (lab_id is null or rgsr.is_lab_member(lab_id))
  and (is_template = false or (is_template = true and rgsr.has_capability('DRIVE_PROFILE_TEMPLATE')))
);

drop policy if exists dp_delete on rgsr.drive_profiles;
create policy dp_delete on rgsr.drive_profiles for delete to authenticated
using (
  rgsr.is_sys_admin()
  or owner_id = auth.uid()
  or (lab_id is not null and rgsr.me_has_lab_capability(lab_id, 'DRIVE_PROFILE_EDIT'))
);

-- Seed a comprehensive drive template library (PUBLISHED) behind the UI controls:
-- Includes waveform, modulation, sweep, pulse, ramps, safety bounds, and UI quick buttons.
do $$
declare seed_owner uuid;
begin
  seed_owner := rgsr._seed_owner_any_user();
  if seed_owner is null then return; end if;

  insert into rgsr.drive_profiles(name, description, lane, is_template, engine_code, owner_id, lab_id, drive_json)
  values (
    'RGSR Drive Baseline (440Hz)',
    'Canonical baseline: 440Hz, sine, gentle amplitude with safety bounds.',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object(
      'units', jsonb_build_object(
        'frequency', 'Hz',
        'amplitude', 'relative',
        'temp', 'C'
      ),
      'core', jsonb_build_object(
        'frequency_hz', 440.0,
        'amplitude', 0.50,
        'waveform', 'sine',
        'phase_deg', 0.0
      ),
      'quick_buttons', jsonb_build_array(440, 528, 1000),
      'modulation', jsonb_build_object(
        'enabled', false,
        'type', 'am',
        'rate_hz', 0.5,
        'depth', 0.25,
        'fm_dev_hz', 5.0
      ),
      'sweep', jsonb_build_object(
        'enabled', false,
        'mode', 'linear',
        'start_hz', 200.0,
        'end_hz', 1200.0,
        'duration_s', 60.0,
        'hold_s', 0.0
      ),
      'pulse', jsonb_build_object(
        'enabled', false,
        'duty_cycle', 0.50,
        'period_s', 2.0,
        'shape', 'square'
      ),
      'ramp', jsonb_build_object(
        'enabled', true,
        'attack_s', 1.0,
        'release_s', 1.0
      ),
      'safety', jsonb_build_object(
        'min_frequency_hz', 0.1,
        'max_frequency_hz', 5000.0,
        'min_amplitude', 0.0,
        'max_amplitude', 1.0,
        'max_rate_of_change_amp_per_s', 0.20
      ),
      'overlays', jsonb_build_object(
        'resonance_field', true,
        'thermal_overlay', false,
        'acoustic_waves', false
      )
    )
  ) on conflict on constraint drive_profiles_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.drive_profiles(name, description, lane, is_template, engine_code, owner_id, lab_id, drive_json)
  values (
    'RGSR Drive Sweep (200-1200Hz)',
    'Canonical sweep profile for discovery runs: linear sweep with logging markers.',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object(
      'units', jsonb_build_object('frequency','Hz','amplitude','relative'),
      'core', jsonb_build_object('frequency_hz', 440.0, 'amplitude', 0.40, 'waveform','sine', 'phase_deg', 0.0),
      'quick_buttons', jsonb_build_array(200, 440, 1200),
      'modulation', jsonb_build_object('enabled', false),
      'sweep', jsonb_build_object('enabled', true, 'mode','linear', 'start_hz',200.0,'end_hz',1200.0,'duration_s',120.0,'hold_s',2.0),
      'pulse', jsonb_build_object('enabled', false),
      'ramp', jsonb_build_object('enabled', true, 'attack_s', 2.0, 'release_s', 2.0),
      'safety', jsonb_build_object('max_frequency_hz', 5000.0, 'max_amplitude', 0.80),
      'markers', jsonb_build_object('enabled', true, 'interval_hz', 50.0)
    )
  ) on conflict on constraint drive_profiles_engine_name_lane_tpl_uq do nothing;

end$$;

-- ------------------------------------------------------------
-- 4) Billing Entitlements (ROOTED-style):
--    - Researcher + Lab: autoapproved (billing success -> activate immediately)
--    - Institution: still uses application + admin decision + billing verify
-- ------------------------------------------------------------
create table if not exists rgsr.billing_entitlements (
  entitlement_id uuid primary key default gen_random_uuid(),
  provider text not null,
  customer_id text not null,
  subscription_id text,
  user_id uuid not null references auth.users(id) on delete cascade,
  plan_id rgsr.rgsr_plan_id not null,
  status text not null default 'ACTIVE',
  effective_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

create unique index if not exists ux_billing_entitlements_provider_customer_plan
  on rgsr.billing_entitlements(provider, customer_id, plan_id);

-- service-only apply entitlement (autoapproved lanes)
create or replace function rgsr.apply_billing_entitlement(
  p_provider text,
  p_customer_id text,
  p_subscription_id text,
  p_user_id uuid,
  p_plan_id rgsr.rgsr_plan_id
) returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
begin
  if not (rgsr.is_sys_admin() or rgsr.is_service_role()) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;

  insert into rgsr.billing_entitlements(provider, customer_id, subscription_id, user_id, plan_id, status)
  values (p_provider, p_customer_id, p_subscription_id, p_user_id, p_plan_id, 'ACTIVE')
  on conflict (provider, customer_id, plan_id) do update
    set subscription_id = excluded.subscription_id,
        user_id = excluded.user_id,
        status = 'ACTIVE',
        effective_at = now();

  -- Apply plan to profile (autoapproved: RESEARCHER_PRO / LAB_STANDARD only)
  if p_plan_id in ('RESEARCHER_PRO'::rgsr.rgsr_plan_id, 'LAB_STANDARD'::rgsr.rgsr_plan_id) then
    update rgsr.user_profiles set plan_id = p_plan_id where user_id = p_user_id;
  end if;
end;
$$;

revoke all on function rgsr.apply_billing_entitlement(text, text, text, uuid, rgsr.rgsr_plan_id) from public;
grant execute on function rgsr.apply_billing_entitlement(text, text, text, uuid, rgsr.rgsr_plan_id) to authenticated;

-- ------------------------------------------------------------
-- 5) Institution Applications (admin review + billing verify -> activate)
--    (If your institution table already exists from earlier work, this is additive-safe.)
-- ------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
                 where n.nspname='rgsr' and t.typname='institution_application_status') then
    create type rgsr.institution_application_status as enum (
      'DRAFT', 'SUBMITTED', 'APPROVED_PENDING_PAYMENT', 'REJECTED', 'ACTIVE'
    );
  end if;
end $$;

create table if not exists rgsr.institution_access_applications (
  application_id uuid primary key default gen_random_uuid(),
  applicant_user_id uuid not null references auth.users(id) on delete cascade,
  applicant_email text,
  org_name text not null,
  org_type text,
  website text,
  country_code text,
  contact_name text,
  contact_phone text,
  requested_seats integer not null default 1 check (requested_seats between 1 and 1000),
  requested_plan_id rgsr.rgsr_plan_id not null default 'INSTITUTION'::rgsr.rgsr_plan_id,
  notes text,
  status rgsr.institution_application_status not null default 'DRAFT',
  submitted_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  decision_reason text,
  billing_provider text,
  billing_customer_id text,
  billing_subscription_id text,
  billing_verified_at timestamptz,
  activated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists ix_inst_apps_applicant on rgsr.institution_access_applications(applicant_user_id, created_at desc);
create index if not exists ix_inst_apps_status on rgsr.institution_access_applications(status, created_at desc);

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_inst_apps_touch') then
    create trigger tr_inst_apps_touch
    before update on rgsr.institution_access_applications
    for each row execute function rgsr.tg_touch_updated_at();
  end if;
end$$;

insert into rgsr.capabilities (capability_id, description) values
  ('INSTITUTION_APPLY', 'Submit an institutional access application'),
  ('INSTITUTION_APP_TRACK', 'View your institutional application tracker/dashboard'),
  ('INSTITUTION_APP_REVIEW', 'Admin can review/approve/reject institutional applications'),
  ('INSTITUTION_BILLING_VERIFY', 'Admin/system can mark billing verified and activate entitlements')
on conflict do nothing;

insert into rgsr.plan_capabilities(plan_id, capability_id, enabled) values
  ('OBSERVER_FREE','INSTITUTION_APPLY', true),
  ('OBSERVER_FREE','INSTITUTION_APP_TRACK', true),
  ('RESEARCHER_PRO','INSTITUTION_APPLY', true),
  ('RESEARCHER_PRO','INSTITUTION_APP_TRACK', true),
  ('LAB_STANDARD','INSTITUTION_APPLY', true),
  ('LAB_STANDARD','INSTITUTION_APP_TRACK', true),
  ('INSTITUTION','INSTITUTION_APP_TRACK', true)
on conflict do nothing;

alter table rgsr.institution_access_applications enable row level security;

drop policy if exists inst_app_select on rgsr.institution_access_applications;
create policy inst_app_select on rgsr.institution_access_applications for select to authenticated
using (rgsr.is_sys_admin() or applicant_user_id = auth.uid());

drop policy if exists inst_app_insert on rgsr.institution_access_applications;
create policy inst_app_insert on rgsr.institution_access_applications for insert to authenticated
with check (applicant_user_id = auth.uid() and rgsr.has_capability('INSTITUTION_APPLY'));

drop policy if exists inst_app_update on rgsr.institution_access_applications;
create policy inst_app_update on rgsr.institution_access_applications for update to authenticated
using (rgsr.is_sys_admin() or applicant_user_id = auth.uid())
with check (rgsr.is_sys_admin() or (applicant_user_id = auth.uid() and status in ('DRAFT','SUBMITTED')));

create or replace function rgsr.submit_institution_application(p_org_name text, p_requested_seats integer, p_payload jsonb default '{}'::jsonb)
returns uuid
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
declare app_id uuid;
begin
  if not rgsr.has_capability('INSTITUTION_APPLY') then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  insert into rgsr.institution_access_applications(
    applicant_user_id, applicant_email, org_name, requested_seats, org_type, website, country_code, contact_name, contact_phone, notes, status, submitted_at, requested_plan_id
  ) values (
    auth.uid(), (select email from auth.users where id = auth.uid()), p_org_name, p_requested_seats,
    nullif(p_payload->>'org_type',''), nullif(p_payload->>'website',''), nullif(p_payload->>'country_code',''),
    nullif(p_payload->>'contact_name',''), nullif(p_payload->>'contact_phone',''), nullif(p_payload->>'notes',''),
    'SUBMITTED', now(), 'INSTITUTION'::rgsr.rgsr_plan_id
  ) returning application_id into app_id;
  return app_id;
end;
$$;

create or replace function rgsr.get_my_institution_applications()
returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'applications', coalesce((
      select jsonb_agg(jsonb_build_object(
        'application_id', a.application_id,
        'org_name', a.org_name,
        'requested_seats', a.requested_seats,
        'status', a.status::text,
        'submitted_at', a.submitted_at,
        'reviewed_at', a.reviewed_at,
        'decision_reason', a.decision_reason,
        'billing_verified_at', a.billing_verified_at,
        'activated_at', a.activated_at,
        'created_at', a.created_at
      ) order by a.created_at desc)
      from rgsr.institution_access_applications a
      where a.applicant_user_id = auth.uid()
    ), '[]'::jsonb)
  );
$$;

create or replace function rgsr.admin_review_institution_application(p_application_id uuid, p_decision text, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
begin
  if not rgsr.is_sys_admin() then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  if p_decision not in ('APPROVE','REJECT') then
    raise exception 'invalid decision' using errcode = 'invalid_parameter_value';
  end if;
  update rgsr.institution_access_applications
  set status = case when p_decision = 'APPROVE' then 'APPROVED_PENDING_PAYMENT' else 'REJECTED' end,
      reviewed_by = auth.uid(),
      reviewed_at = now(),
      decision_reason = p_reason
  where application_id = p_application_id
    and status = 'SUBMITTED';
end;
$$;

create or replace function rgsr.admin_verify_institution_billing_and_activate(p_application_id uuid, p_provider text, p_customer_id text, p_subscription_id text)
returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
declare uid uuid;
begin
  if not (rgsr.is_sys_admin() or rgsr.is_service_role()) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  select a.applicant_user_id into uid
  from rgsr.institution_access_applications a
  where a.application_id = p_application_id
    and a.status = 'APPROVED_PENDING_PAYMENT';
  if uid is null then
    raise exception 'application not eligible for activation' using errcode = 'check_violation';
  end if;
  update rgsr.institution_access_applications
  set billing_provider = p_provider,
      billing_customer_id = p_customer_id,
      billing_subscription_id = p_subscription_id,
      billing_verified_at = now(),
      status = 'ACTIVE',
      activated_at = now()
  where application_id = p_application_id;
  update rgsr.user_profiles set plan_id = 'INSTITUTION'::rgsr.rgsr_plan_id where user_id = uid;
end;
$$;

revoke all on function rgsr.submit_institution_application(text, integer, jsonb) from public;
revoke all on function rgsr.admin_review_institution_application(uuid, text, text) from public;
revoke all on function rgsr.admin_verify_institution_billing_and_activate(uuid, text, text, text) from public;
grant execute on function rgsr.submit_institution_application(text, integer, jsonb) to authenticated;
grant execute on function rgsr.get_my_institution_applications() to authenticated;
grant execute on function rgsr.admin_review_institution_application(uuid, text, text) to authenticated;
grant execute on function rgsr.admin_verify_institution_billing_and_activate(uuid, text, text, text) to authenticated;

-- ------------------------------------------------------------
-- 6) Password Policy Core (ROOTED-style): rotation + history
--    DB side is canonical source of truth; enforcement is done via service-role hook/RPC.
-- ------------------------------------------------------------
create table if not exists rgsr.password_policy (
  policy_id text primary key default 'DEFAULT',
  min_length int not null default 14,
  require_upper boolean not null default true,
  require_lower boolean not null default true,
  require_number boolean not null default true,
  require_symbol boolean not null default true,
  history_count int not null default 12,
  rotate_days int not null default 90,
  created_at timestamptz not null default now()
);

insert into rgsr.password_policy(policy_id) values ('DEFAULT') on conflict do nothing;

create table if not exists rgsr.password_history (
  user_id uuid not null references auth.users(id) on delete cascade,
  password_hash text not null,
  created_at timestamptz not null default now()
);
create index if not exists ix_password_history_user_time on rgsr.password_history(user_id, created_at desc);

create table if not exists rgsr.password_rotation (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_changed_at timestamptz not null default now(),
  next_required_at timestamptz not null default (now() + interval '90 days')
);

create or replace function rgsr._password_meets_policy(p_password text)
returns boolean language plpgsql stable as $$
declare pol record;
begin
  select * into pol from rgsr.password_policy where policy_id = 'DEFAULT';
  if p_password is null or length(p_password) < pol.min_length then return false; end if;
  if pol.require_upper and p_password !~ '[A-Z]' then return false; end if;
  if pol.require_lower and p_password !~ '[a-z]' then return false; end if;
  if pol.require_number and p_password !~ '[0-9]' then return false; end if;
  if pol.require_symbol and p_password !~ '[^A-Za-z0-9]' then return false; end if;
  return true;
end;
$$;

create or replace function rgsr._password_is_reused(p_user uuid, p_password text)
returns boolean
language sql
stable
as $rgsr$
  select exists (
    select 1 from rgsr.password_history h
    where h.user_id = p_user
      and h.password_hash = extensions.crypt(p_password, h.password_hash)
  );
$rgsr$;
create or replace function rgsr.service_record_password_change(p_user uuid, p_new_password text)
returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
declare pol record;
begin
  if not (rgsr.is_sys_admin() or rgsr.is_service_role()) then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  if not rgsr._password_meets_policy(p_new_password) then
    raise exception 'password does not meet policy' using errcode = 'invalid_parameter_value';
  end if;
  if rgsr._password_is_reused(p_user, p_new_password) then
    raise exception 'password reuse not allowed' using errcode = 'invalid_parameter_value';
  end if;
  select * into pol from rgsr.password_policy where policy_id = 'DEFAULT';
  insert into rgsr.password_history(user_id, password_hash)
  values (p_user, crypt(p_new_password, gen_salt('bf'))) ;
  delete from rgsr.password_history
  where user_id = p_user
    and ctid in (
      select ctid from rgsr.password_history
      where user_id = p_user
      order by created_at desc
      offset pol.history_count
    );
  insert into rgsr.password_rotation(user_id, last_changed_at, next_required_at)
  values (p_user, now(), now() + (pol.rotate_days || ' days')::interval)
  on conflict (user_id) do update
    set last_changed_at = now(), next_required_at = now() + (pol.rotate_days || ' days')::interval;
end;
$$;

revoke all on function rgsr.service_record_password_change(uuid, text) from public;
grant execute on function rgsr.service_record_password_change(uuid, text) to authenticated;

commit;

-- ============================================================
-- End migration
-- ============================================================
