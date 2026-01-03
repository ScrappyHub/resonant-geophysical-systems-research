-- ============================================================
-- RGSR: Profile Menu + Seat Overrides + Geometry Templates (V1)
-- Canonical: profile actions, team actions, geometry library/templates
-- RLS: private by default; lab-shared only when seat allows; published templates readable
-- ============================================================

begin;

create extension if not exists pgcrypto;

-- 1) Capabilities (geometry + access controls for profile menu)
insert into rgsr.capabilities (capability_id, description) values
  ('GEOMETRY_VIEW',          'View geometry library (private + lab + published)'),
  ('GEOMETRY_CREATE',        'Create private geometry sets'),
  ('GEOMETRY_EDIT',          'Edit geometry sets you own (or lab-permitted)'),
  ('GEOMETRY_SHARE_LAB',     'Share geometry sets into LAB lane'),
  ('GEOMETRY_TEMPLATE',      'Mark geometry sets as templates'),
  ('GEOMETRY_PUBLISH',       'Publish geometry templates (PUBLISHED lane)'),
  ('SEAT_GRANT',             'Grant/revoke per-member capability overrides inside a lab')
on conflict do nothing;

-- 2) Seed plan capabilities (baseline; you can tighten later)
-- Everyone who is authenticated can VIEW geometry library:
insert into rgsr.plan_capabilities(plan_id, capability_id, enabled) values
  ('OBSERVER_FREE','GEOMETRY_VIEW', true),
  ('RESEARCHER_PRO','GEOMETRY_VIEW', true),
  ('LAB_STANDARD','GEOMETRY_VIEW', true),
  ('INSTITUTION','GEOMETRY_VIEW', true)
on conflict do nothing;

-- Create/edit rights by plan:
insert into rgsr.plan_capabilities(plan_id, capability_id, enabled) values
  ('RESEARCHER_PRO','GEOMETRY_CREATE', true),
  ('RESEARCHER_PRO','GEOMETRY_EDIT', true),
  ('LAB_STANDARD','GEOMETRY_CREATE', true),
  ('LAB_STANDARD','GEOMETRY_EDIT', true),
  ('LAB_STANDARD','GEOMETRY_SHARE_LAB', true),
  ('INSTITUTION','GEOMETRY_CREATE', true),
  ('INSTITUTION','GEOMETRY_EDIT', true),
  ('INSTITUTION','GEOMETRY_SHARE_LAB', true),
  ('INSTITUTION','GEOMETRY_TEMPLATE', true),
  ('INSTITUTION','GEOMETRY_PUBLISH', true)
on conflict do nothing;

-- 3) Seed seat (lab role) capabilities
-- VIEWER: view only; MEMBER: create/edit own; ADMIN/OWNER: manage/share/templates/publish
insert into rgsr.lab_role_capabilities (lab_role, capability_id, enabled) values
  ('VIEWER','GEOMETRY_VIEW', true),
  ('MEMBER','GEOMETRY_VIEW', true),
  ('MEMBER','GEOMETRY_CREATE', true),
  ('MEMBER','GEOMETRY_EDIT', true),
  ('ADMIN','GEOMETRY_VIEW', true),
  ('ADMIN','GEOMETRY_CREATE', true),
  ('ADMIN','GEOMETRY_EDIT', true),
  ('ADMIN','GEOMETRY_SHARE_LAB', true),
  ('ADMIN','GEOMETRY_TEMPLATE', true),
  ('OWNER','GEOMETRY_VIEW', true),
  ('OWNER','GEOMETRY_CREATE', true),
  ('OWNER','GEOMETRY_EDIT', true),
  ('OWNER','GEOMETRY_SHARE_LAB', true),
  ('OWNER','GEOMETRY_TEMPLATE', true),
  ('OWNER','GEOMETRY_PUBLISH', true),
  ('ADMIN','SEAT_GRANT', true),
  ('OWNER','SEAT_GRANT', true)
on conflict do nothing;

-- 4) Per-member overrides (granular access controls inside a lab)
create table if not exists rgsr.lab_member_capability_overrides (
  lab_id         uuid not null references rgsr.labs(lab_id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  capability_id  text not null references rgsr.capabilities(capability_id) on delete cascade,
  enabled        boolean not null,
  created_by     uuid not null references auth.users(id) on delete cascade,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (lab_id, user_id, capability_id)
);

create or replace function rgsr.tg_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_lab_member_overrides_touch') then
    create trigger tr_lab_member_overrides_touch
    before update on rgsr.lab_member_capability_overrides
    for each row execute function rgsr.tg_touch_updated_at();
  end if;
end$$;

-- Effective seat capability: overrides > seat role caps > sys admin
create or replace function rgsr.has_lab_capability_effective(p_lab uuid, p_user uuid, p_cap text)
returns boolean
language sql stable as $$
  select rgsr.is_sys_admin()
  or coalesce((
    select o.enabled
    from rgsr.lab_member_capability_overrides o
    where o.lab_id = p_lab and o.user_id = p_user and o.capability_id = p_cap
  ), (
    select exists (
      select 1 from rgsr.lab_role_capabilities lrc
      where lrc.lab_role = rgsr.current_lab_role(p_lab)
        and lrc.capability_id = p_cap
        and lrc.enabled
    )
  ));
$$;

-- Convenience: current user + lab
create or replace function rgsr.me_has_lab_capability(p_lab uuid, p_cap text)
returns boolean
language sql stable as $$
  select rgsr.has_lab_capability_effective(p_lab, auth.uid(), p_cap);
$$;

-- 5) Geometry library: sets with JSON definition, lane-aware
create table if not exists rgsr.geometry_sets (
  geometry_id    uuid primary key default gen_random_uuid(),
  name           text not null,
  description    text,
  lane           rgsr.rgsr_lane not null default 'PRIVATE',
  is_template    boolean not null default false,
  engine_code    text not null default 'RGSR',
  owner_id       uuid not null references auth.users(id) on delete cascade,
  lab_id         uuid references rgsr.labs(lab_id) on delete set null,
  geometry_json  jsonb not null,
  dims_json      jsonb,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_geometry_sets_touch') then
    create trigger tr_geometry_sets_touch
    before update on rgsr.geometry_sets
    for each row execute function rgsr.tg_touch_updated_at();
  end if;
end$$;

-- Forward-only lane for geometry (reuse lane_rank)
create or replace function rgsr.tg_geometry_lane_forward_only()
returns trigger language plpgsql as $$
begin
  if (tg_op = 'UPDATE') then
    if rgsr.lane_rank(new.lane) < rgsr.lane_rank(old.lane) then
      raise exception 'Geometry lane is forward-only: % -> % is not allowed', old.lane, new.lane
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end$$;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_geometry_lane_forward_only') then
    create trigger tr_geometry_lane_forward_only
    before update of lane on rgsr.geometry_sets
    for each row execute function rgsr.tg_geometry_lane_forward_only();
  end if;
end$$;

-- 6) Geometry read/write rules
create or replace function rgsr.can_read_geometry(p_lane rgsr.rgsr_lane, p_owner uuid, p_lab uuid)
returns boolean
language sql stable as $$
  select rgsr.is_sys_admin()
  or case p_lane
    when 'PUBLISHED' then true
    when 'PRIVATE' then (auth.uid() = p_owner) and rgsr.has_capability('GEOMETRY_VIEW')
    when 'LAB' then (p_lab is not null and rgsr.is_lab_member(p_lab) and rgsr.has_capability('GEOMETRY_VIEW'))
    when 'REVIEW' then (p_lab is not null and rgsr.is_lab_member(p_lab) and rgsr.has_capability('GEOMETRY_VIEW'))
  end;
$$;

create or replace function rgsr.can_write_geometry_target(p_lane rgsr.rgsr_lane, p_lab uuid)
returns boolean
language sql stable as $$
  select rgsr.is_sys_admin()
  or case p_lane
    when 'PRIVATE' then rgsr.has_capability('GEOMETRY_CREATE')
    when 'LAB' then (p_lab is not null and rgsr.me_has_lab_capability(p_lab, 'GEOMETRY_SHARE_LAB') and rgsr.has_capability('GEOMETRY_CREATE'))
    when 'REVIEW' then (p_lab is not null and rgsr.me_has_lab_capability(p_lab, 'GEOMETRY_SHARE_LAB') and rgsr.has_capability('GEOMETRY_CREATE'))
    when 'PUBLISHED' then (rgsr.has_capability('GEOMETRY_PUBLISH'))
  end;
$$;

-- 7) RLS: geometry library is private by default
alter table rgsr.geometry_sets enable row level security;
alter table rgsr.lab_member_capability_overrides enable row level security;

-- geometry select
drop policy if exists gs_select on rgsr.geometry_sets;
create policy gs_select on rgsr.geometry_sets for select to authenticated
using (rgsr.can_read_geometry(lane, owner_id, lab_id));

-- geometry insert (must be owner; lane target must be allowed; lab_id must be member if present)
drop policy if exists gs_insert on rgsr.geometry_sets;
create policy gs_insert on rgsr.geometry_sets for insert to authenticated
with check (
  owner_id = auth.uid()
  and rgsr.can_write_geometry_target(lane, lab_id)
  and (lab_id is null or rgsr.is_lab_member(lab_id))
);

-- geometry update (owner or lab-admin; lane changes still forward-only by trigger)
drop policy if exists gs_update on rgsr.geometry_sets;
create policy gs_update on rgsr.geometry_sets for update to authenticated
using (
  rgsr.is_sys_admin()
  or owner_id = auth.uid()
  or (lab_id is not null and rgsr.me_has_lab_capability(lab_id, 'GEOMETRY_EDIT'))
)
with check (
  rgsr.can_write_geometry_target(lane, lab_id)
  and (lab_id is null or rgsr.is_lab_member(lab_id))
  and (
    (is_template = false)
    or (is_template = true and rgsr.has_capability('GEOMETRY_TEMPLATE'))
  )
);

-- geometry delete (owner or lab-admin)
drop policy if exists gs_delete on rgsr.geometry_sets;
create policy gs_delete on rgsr.geometry_sets for delete to authenticated
using (
  rgsr.is_sys_admin()
  or owner_id = auth.uid()
  or (lab_id is not null and rgsr.me_has_lab_capability(lab_id, 'GEOMETRY_EDIT'))
);

-- overrides: only seat-granters (ADMIN/OWNER) can view or change overrides in their lab
drop policy if exists ovr_select on rgsr.lab_member_capability_overrides;
create policy ovr_select on rgsr.lab_member_capability_overrides for select to authenticated
using (rgsr.is_sys_admin() or rgsr.me_has_lab_capability(lab_id, 'SEAT_GRANT'));

drop policy if exists ovr_insert on rgsr.lab_member_capability_overrides;
create policy ovr_insert on rgsr.lab_member_capability_overrides for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.me_has_lab_capability(lab_id, 'SEAT_GRANT'));

drop policy if exists ovr_update on rgsr.lab_member_capability_overrides;
create policy ovr_update on rgsr.lab_member_capability_overrides for update to authenticated
using (rgsr.is_sys_admin() or rgsr.me_has_lab_capability(lab_id, 'SEAT_GRANT'))
with check (rgsr.is_sys_admin() or rgsr.me_has_lab_capability(lab_id, 'SEAT_GRANT'));

drop policy if exists ovr_delete on rgsr.lab_member_capability_overrides;
create policy ovr_delete on rgsr.lab_member_capability_overrides for delete to authenticated
using (rgsr.is_sys_admin() or rgsr.me_has_lab_capability(lab_id, 'SEAT_GRANT'));

-- 8) Profile Menu RPCs (for UI dropdown)
create or replace function rgsr.get_my_profile_menu()
returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'user_id', up.user_id,
    'display_name', up.display_name,
    'role_id', up.role_id,
    'plan_id', up.plan_id,
    'labs', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'lab_id', l.lab_id,
        'name', l.name,
        'seat_role', rgsr.current_lab_role(l.lab_id),
        'can_team_manage', rgsr.me_has_lab_capability(l.lab_id, 'TEAM_MANAGE'),
        'can_team_invite', rgsr.me_has_lab_capability(l.lab_id, 'TEAM_INVITE'),
        'can_seat_grant', rgsr.me_has_lab_capability(l.lab_id, 'SEAT_GRANT'),
        'can_geometry_share_lab', rgsr.me_has_lab_capability(l.lab_id, 'GEOMETRY_SHARE_LAB'),
        'can_geometry_edit', rgsr.me_has_lab_capability(l.lab_id, 'GEOMETRY_EDIT')
      ) order by l.created_at), '[]'::jsonb)
      from rgsr.labs l
      where exists (select 1 from rgsr.lab_members lm where lm.lab_id = l.lab_id and lm.user_id = auth.uid())
         or l.owner_id = auth.uid()
    ),
    'capabilities', jsonb_build_object(
      'profile_edit', rgsr.has_capability('PROFILE_EDIT'),
      'geometry_view', rgsr.has_capability('GEOMETRY_VIEW'),
      'geometry_create', rgsr.has_capability('GEOMETRY_CREATE'),
      'geometry_template', rgsr.has_capability('GEOMETRY_TEMPLATE'),
      'geometry_publish', rgsr.has_capability('GEOMETRY_PUBLISH')
    )
  )
  from rgsr.user_profiles up
  where up.user_id = auth.uid();
$$;

create or replace function rgsr.update_my_profile(p_display_name text)
returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
begin
  if not rgsr.has_capability('PROFILE_EDIT') then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  update rgsr.user_profiles
  set display_name = nullif(trim(p_display_name), '')
  where user_id = auth.uid();
end;
$$;

commit;

-- ============================================================
-- End migration
-- ============================================================
