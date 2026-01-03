-- ============================================================
-- RGSR: Env Profiles (Lane-aware) + Full Geometry Library + Team RPCs (V1)
-- Canonical goals:
--  - Condition profiles behave like geometry: PRIVATE / LAB / PUBLISHED (templates)
--  - Seeds match UI (more than 2 models + real template catalog)
--  - Team management RPCs for Profile menu (edit team / seats / overrides / invites)
--  - RLS: private by default, lab-private roster, published templates globally readable
-- ============================================================

begin;

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 0) Helpers
-- ------------------------------------------------------------
create or replace function rgsr._seed_owner_any_user()
returns uuid language sql stable as $$
  select coalesce(
    (select up.user_id from rgsr.user_profiles up where up.role_id = 'SYS_ADMIN'::rgsr.rgsr_role_id order by up.created_at asc limit 1),
    (select up.user_id from rgsr.user_profiles up order by up.created_at asc limit 1)
  );
$$;

create or replace function rgsr.tg_touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- ------------------------------------------------------------
-- 1) Capabilities: Environment Profiles (Condition Profiles) + Team UI RPC gating
-- ------------------------------------------------------------
insert into rgsr.capabilities (capability_id, description) values
  ('ENV_PROFILE_VIEW',      'View environment/condition profiles (private + lab + published)'),
  ('ENV_PROFILE_CREATE',    'Create private environment/condition profiles'),
  ('ENV_PROFILE_EDIT',      'Edit environment/condition profiles you own (or lab-permitted)'),
  ('ENV_PROFILE_SHARE_LAB', 'Share environment/condition profiles into LAB lane'),
  ('ENV_PROFILE_TEMPLATE',  'Mark environment profiles as templates'),
  ('ENV_PROFILE_PUBLISH',   'Publish environment templates (PUBLISHED lane)'),
  ('TEAM_ROSTER_VIEW',      'View lab roster details for team management UI' )
on conflict do nothing;

-- Plans: baseline view for authenticated users (tighten later if you want)
insert into rgsr.plan_capabilities(plan_id, capability_id, enabled) values
  ('OBSERVER_FREE','ENV_PROFILE_VIEW', true),
  ('RESEARCHER_PRO','ENV_PROFILE_VIEW', true),
  ('LAB_STANDARD','ENV_PROFILE_VIEW', true),
  ('INSTITUTION','ENV_PROFILE_VIEW', true)
on conflict do nothing;

-- Creation/edit by plan
insert into rgsr.plan_capabilities(plan_id, capability_id, enabled) values
  ('RESEARCHER_PRO','ENV_PROFILE_CREATE', true),
  ('RESEARCHER_PRO','ENV_PROFILE_EDIT', true),
  ('LAB_STANDARD','ENV_PROFILE_CREATE', true),
  ('LAB_STANDARD','ENV_PROFILE_EDIT', true),
  ('LAB_STANDARD','ENV_PROFILE_SHARE_LAB', true),
  ('INSTITUTION','ENV_PROFILE_CREATE', true),
  ('INSTITUTION','ENV_PROFILE_EDIT', true),
  ('INSTITUTION','ENV_PROFILE_SHARE_LAB', true),
  ('INSTITUTION','ENV_PROFILE_TEMPLATE', true),
  ('INSTITUTION','ENV_PROFILE_PUBLISH', true)
on conflict do nothing;

-- Seat (lab role) capabilities (VIEWER view-only; MEMBER create/edit own; ADMIN/OWNER share/template/publish)
insert into rgsr.lab_role_capabilities (lab_role, capability_id, enabled) values
  ('VIEWER','ENV_PROFILE_VIEW', true),
  ('MEMBER','ENV_PROFILE_VIEW', true),
  ('MEMBER','ENV_PROFILE_CREATE', true),
  ('MEMBER','ENV_PROFILE_EDIT', true),
  ('ADMIN','ENV_PROFILE_VIEW', true),
  ('ADMIN','ENV_PROFILE_CREATE', true),
  ('ADMIN','ENV_PROFILE_EDIT', true),
  ('ADMIN','ENV_PROFILE_SHARE_LAB', true),
  ('ADMIN','ENV_PROFILE_TEMPLATE', true),
  ('OWNER','ENV_PROFILE_VIEW', true),
  ('OWNER','ENV_PROFILE_CREATE', true),
  ('OWNER','ENV_PROFILE_EDIT', true),
  ('OWNER','ENV_PROFILE_SHARE_LAB', true),
  ('OWNER','ENV_PROFILE_TEMPLATE', true),
  ('OWNER','ENV_PROFILE_PUBLISH', true),
  ('ADMIN','TEAM_ROSTER_VIEW', true),
  ('OWNER','TEAM_ROSTER_VIEW', true)
on conflict do nothing;

-- ------------------------------------------------------------
-- 2) Upgrade rgsr.condition_profiles into lane-aware + template-capable
--    (Preserves existing data; makes it per-owner and private by default)
-- ------------------------------------------------------------
alter table rgsr.condition_profiles add column if not exists lane rgsr.rgsr_lane not null default 'PRIVATE';
alter table rgsr.condition_profiles add column if not exists is_template boolean not null default false;
alter table rgsr.condition_profiles add column if not exists engine_code text not null default 'RGSR';
alter table rgsr.condition_profiles add column if not exists owner_id uuid;
alter table rgsr.condition_profiles add column if not exists lab_id uuid references rgsr.labs(lab_id) on delete set null;
alter table rgsr.condition_profiles add column if not exists updated_at timestamptz not null default now();

-- Backfill owner_id from created_by (canonical)
update rgsr.condition_profiles set owner_id = created_by where owner_id is null;

-- Enforce FK (only if auth.users exists row, which it does for created_by)
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'condition_profiles_owner_fk') then
    alter table rgsr.condition_profiles
      add constraint condition_profiles_owner_fk foreign key (owner_id) references auth.users(id) on delete cascade;
  end if;
end$$;

-- Ensure owner_id NOT NULL after backfill
do $$
begin
  if not exists (select 1 from rgsr.condition_profiles where owner_id is null) then
    alter table rgsr.condition_profiles alter column owner_id set not null;
  end if;
end$$;

-- Drop the global UNIQUE(profile_name) if it exists; replace with per-owner uniqueness
do $$
declare c record;
begin
  for c in
    select conname
    from pg_constraint
    join pg_class on pg_class.oid = pg_constraint.conrelid
    join pg_namespace n on n.oid = pg_class.relnamespace
    where n.nspname = 'rgsr' and pg_class.relname = 'condition_profiles'
      and pg_constraint.contype = 'u'
  loop
    -- if the constraint touches profile_name, drop it
    if exists (
      select 1
      from pg_attribute a
      join pg_constraint ct on ct.conrelid = a.attrelid
      where ct.conname = c.conname and a.attname = 'profile_name' and a.attnum = any(ct.conkey)
    ) then
      execute format('alter table rgsr.condition_profiles drop constraint %I', c.conname);
    end if;
  end loop;
end$$;

-- New uniqueness: per-owner profile_name + stable published template uniqueness
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'condition_profiles_owner_name_uq') then
    alter table rgsr.condition_profiles add constraint condition_profiles_owner_name_uq unique (owner_id, profile_name);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'condition_profiles_engine_name_lane_tpl_uq') then
    alter table rgsr.condition_profiles add constraint condition_profiles_engine_name_lane_tpl_uq unique (engine_code, profile_name, lane, is_template);
  end if;
end$$;

-- Touch trigger
do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_condition_profiles_touch') then
    create trigger tr_condition_profiles_touch
    before update on rgsr.condition_profiles
    for each row execute function rgsr.tg_touch_updated_at();
  end if;
end$$;

-- Forward-only lane for env profiles
create or replace function rgsr.tg_condition_profile_lane_forward_only()
returns trigger language plpgsql as $$
begin
  if (tg_op = 'UPDATE') then
    if rgsr.lane_rank(new.lane) < rgsr.lane_rank(old.lane) then
      raise exception 'Env profile lane is forward-only: % -> % is not allowed', old.lane, new.lane
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end$$;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_condition_profiles_lane_forward_only') then
    create trigger tr_condition_profiles_lane_forward_only
    before update of lane on rgsr.condition_profiles
    for each row execute function rgsr.tg_condition_profile_lane_forward_only();
  end if;
end$$;

-- Read/write helpers (env profiles)
create or replace function rgsr.can_read_env_profile(p_lane rgsr.rgsr_lane, p_owner uuid, p_lab uuid)
returns boolean language sql stable as $$
  select rgsr.is_sys_admin()
  or case p_lane
    when 'PUBLISHED' then true
    when 'PRIVATE' then (auth.uid() = p_owner) and rgsr.has_capability('ENV_PROFILE_VIEW')
    when 'LAB' then (p_lab is not null and rgsr.is_lab_member(p_lab) and rgsr.has_capability('ENV_PROFILE_VIEW'))
    when 'REVIEW' then (p_lab is not null and rgsr.is_lab_member(p_lab) and rgsr.has_capability('ENV_PROFILE_VIEW'))
  end;
$$;

create or replace function rgsr.can_write_env_profile_target(p_lane rgsr.rgsr_lane, p_lab uuid)
returns boolean language sql stable as $$
  select rgsr.is_sys_admin()
  or case p_lane
    when 'PRIVATE' then rgsr.has_capability('ENV_PROFILE_CREATE')
    when 'LAB' then (p_lab is not null and rgsr.me_has_lab_capability(p_lab, 'ENV_PROFILE_SHARE_LAB') and rgsr.has_capability('ENV_PROFILE_CREATE'))
    when 'REVIEW' then (p_lab is not null and rgsr.me_has_lab_capability(p_lab, 'ENV_PROFILE_SHARE_LAB') and rgsr.has_capability('ENV_PROFILE_CREATE'))
    when 'PUBLISHED' then rgsr.has_capability('ENV_PROFILE_PUBLISH')
  end;
$$;

-- RLS for env profiles
alter table rgsr.condition_profiles enable row level security;

drop policy if exists cp_select on rgsr.condition_profiles;
create policy cp_select on rgsr.condition_profiles for select to authenticated
using (rgsr.can_read_env_profile(lane, owner_id, lab_id));

drop policy if exists cp_insert on rgsr.condition_profiles;
create policy cp_insert on rgsr.condition_profiles for insert to authenticated
with check (
  owner_id = auth.uid()
  and rgsr.can_write_env_profile_target(lane, lab_id)
  and (lab_id is null or rgsr.is_lab_member(lab_id))
);

drop policy if exists cp_update on rgsr.condition_profiles;
create policy cp_update on rgsr.condition_profiles for update to authenticated
using (
  rgsr.is_sys_admin()
  or owner_id = auth.uid()
  or (lab_id is not null and rgsr.me_has_lab_capability(lab_id, 'ENV_PROFILE_EDIT'))
)
with check (
  rgsr.can_write_env_profile_target(lane, lab_id)
  and (lab_id is null or rgsr.is_lab_member(lab_id))
  and (is_template = false or (is_template = true and rgsr.has_capability('ENV_PROFILE_TEMPLATE')))
);

drop policy if exists cp_delete on rgsr.condition_profiles;
create policy cp_delete on rgsr.condition_profiles for delete to authenticated
using (
  rgsr.is_sys_admin()
  or owner_id = auth.uid()
  or (lab_id is not null and rgsr.me_has_lab_capability(lab_id, 'ENV_PROFILE_EDIT'))
);

-- ------------------------------------------------------------
-- 3) Team RPCs for Profile Menu (edit team / overrides / invites)
-- ------------------------------------------------------------
create or replace function rgsr.get_lab_team(p_lab uuid)
returns jsonb
language sql
stable
as $rgsr$
  select jsonb_build_object(
    'lab_id', p_lab,
    'members', coalesce(
      (
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
      ),
      '[]'::jsonb
    )
  );
$rgsr$;
create or replace function rgsr.set_lab_member_role(p_lab uuid, p_user uuid, p_role rgsr.rgsr_lab_role)
returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
declare
  owner uuid;
begin
  if not rgsr.has_lab_capability(p_lab, 'TEAM_MANAGE') then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;

  select l.owner_id into owner from rgsr.labs l where l.lab_id = p_lab;
  if owner is null then return; end if;

  if p_user = owner and p_role <> 'OWNER' then
    raise exception 'cannot change lab owner role' using errcode = 'insufficient_privilege';
  end if;

  update rgsr.lab_members
  set seat_role = p_role,
      is_admin = (p_role in ('OWNER','ADMIN'))
  where lab_id = p_lab and user_id = p_user;
end;
$$;

create or replace function rgsr.remove_lab_member(p_lab uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
declare owner uuid;
begin
  if not rgsr.has_lab_capability(p_lab, 'TEAM_MANAGE') then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  select l.owner_id into owner from rgsr.labs l where l.lab_id = p_lab;
  if p_user = owner then
    raise exception 'cannot remove lab owner' using errcode = 'insufficient_privilege';
  end if;
  delete from rgsr.lab_member_capability_overrides where lab_id = p_lab and user_id = p_user;
  delete from rgsr.lab_members where lab_id = p_lab and user_id = p_user;
end;
$$;

create or replace function rgsr.leave_lab(p_lab uuid)
returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
declare owner uuid;
begin
  select l.owner_id into owner from rgsr.labs l where l.lab_id = p_lab;
  if auth.uid() = owner then
    raise exception 'owner cannot leave lab' using errcode = 'insufficient_privilege';
  end if;
  delete from rgsr.lab_member_capability_overrides where lab_id = p_lab and user_id = auth.uid();
  delete from rgsr.lab_members where lab_id = p_lab and user_id = auth.uid();
end;
$$;

create or replace function rgsr.get_lab_invites(p_lab uuid)
returns jsonb
language sql
stable
as $rgsr$
  select jsonb_build_object(
    'lab_id', p_lab,
    'invites', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'invite_id', li.invite_id,
            'email', li.email,
            'seat_role', li.seat_role,
            'status', li.status,
            'created_at', li.created_at,
            'expires_at', li.expires_at
          )
          order by li.created_at desc
        )
        from rgsr.lab_invites li
        where li.lab_id = p_lab
          and rgsr.is_lab_member(p_lab)
          and rgsr.me_has_lab_capability(p_lab, 'TEAM_INVITES_VIEW')
      ),
      '[]'::jsonb
    )
  );
$rgsr$;
create or replace function rgsr.upsert_member_capability_override(p_lab uuid, p_user uuid, p_cap text, p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
begin
  if not rgsr.me_has_lab_capability(p_lab, 'SEAT_GRANT') then
    raise exception 'not authorized' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from rgsr.capabilities c where c.capability_id = p_cap) then
    raise exception 'unknown capability' using errcode = 'invalid_parameter_value';
  end if;
  insert into rgsr.lab_member_capability_overrides(lab_id, user_id, capability_id, enabled, created_by)
  values (p_lab, p_user, p_cap, p_enabled, auth.uid())
  on conflict (lab_id, user_id, capability_id) do update
    set enabled = excluded.enabled,
        updated_at = now();
end;
$$;

-- ------------------------------------------------------------
-- 4) Seed FULL Geometry Template Library (PUBLISHED templates)
--    (Matches UI set you posted; deterministic + canonical)
-- ------------------------------------------------------------
do $$
declare seed_owner uuid;
begin
  seed_owner := rgsr._seed_owner_any_user();
  if seed_owner is null then
    return;
  end if;

  -- Ensure template uniqueness at table level (prevents duplicates on re-run)
  if not exists (select 1 from pg_constraint where conname = 'geometry_sets_engine_name_lane_tpl_uq') then
    alter table rgsr.geometry_sets add constraint geometry_sets_engine_name_lane_tpl_uq unique (engine_code, name, lane, is_template);
  end if;

  -- GRIDS
  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    '6x6 Grid',
    'Standard grid configuration (Phase A baseline)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object(
      'type','grid','rows',6,'cols',6,'category','Grid',
      'nodes', (
        select jsonb_agg(jsonb_build_object(
          'id', format('%s%s', chr(64+xc), yc),
          'x', xc, 'y', yc
        ) order by yc, xc)
        from generate_series(1,6) yc cross join generate_series(1,6) xc
      )
    ),
    jsonb_build_object('units','cm','spacing',jsonb_build_object('x',10,'y',10),'origin',jsonb_build_object('x',0,'y',0))
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    '8x8 Grid',
    'Expanded grid layout (higher node density)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object(
      'type','grid','rows',8,'cols',8,'category','Grid',
      'nodes', (
        select jsonb_agg(jsonb_build_object(
          'id', format('%s%s', chr(64+xc), yc),
          'x', xc, 'y', yc
        ) order by yc, xc)
        from generate_series(1,8) yc cross join generate_series(1,8) xc
      )
    ),
    jsonb_build_object('units','cm','spacing',jsonb_build_object('x',10,'y',10),'origin',jsonb_build_object('x',0,'y',0))
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    '12x12 Grid',
    'Large-scale grid pattern (stress & stability testing)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object(
      'type','grid','rows',12,'cols',12,'category','Grid',
      'nodes', (
        select jsonb_agg(jsonb_build_object(
          'id', format('%s%s', chr(64+xc), yc),
          'x', xc, 'y', yc
        ) order by yc, xc)
        from generate_series(1,12) yc cross join generate_series(1,12) xc
      )
    ),
    jsonb_build_object('units','cm','spacing',jsonb_build_object('x',8,'y',8),'origin',jsonb_build_object('x',0,'y',0))
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  -- PYRAMIDS
  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'Pyramid (4-sided)',
    'Classic tetrahedron-style pyramid mapping placeholder',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object('type','pyramid','sides',4,'tiers',4,'category','Geometric','notes','Symbolic topology; wire real coordinates when instrumentation is defined.'),
    jsonb_build_object('units','cm','bounds',jsonb_build_object('width',60,'depth',60,'height',50))
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'Pyramid (8-sided)',
    'Octagonal pyramid mapping placeholder',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object('type','pyramid','sides',8,'tiers',5,'category','Geometric','notes','Symbolic topology; wire real coordinates when instrumentation is defined.'),
    jsonb_build_object('units','cm','bounds',jsonb_build_object('width',80,'depth',80,'height',60))
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  -- LATTICES / PATTERNS (generator-style)
  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'Hexagonal Lattice',
    'Honeycomb structure (lattice coupling tests)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object('type','hex_lattice','category','Lattice','generator',jsonb_build_object('rings',4,'spacing_cm',8)),
    jsonb_build_object('units','cm','notes','Generator-defined lattice; engine expands nodes.' )
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'Triangular Grid',
    'Triangular tessellation (anisotropy tests)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object('type','tri_grid','category','Pattern','generator',jsonb_build_object('rows',8,'cols',8,'spacing_cm',8)),
    jsonb_build_object('units','cm','notes','Generator-defined; engine expands.' )
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'Voronoi Diagram',
    'Organic cell-like pattern (heterogeneity tests)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object('type','voronoi','category','Pattern','generator',jsonb_build_object('seeds',24,'bounds_cm',jsonb_build_object('w',80,'h',80))),
    jsonb_build_object('units','cm','notes','Generator-defined; deterministic via run hash seed.' )
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'Fibonacci Spiral',
    'Golden ratio spiral (pattern resonance tests)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object('type','fibonacci_spiral','category','Pattern','generator',jsonb_build_object('turns',6,'points',144,'scale_cm',80)),
    jsonb_build_object('units','cm','notes','Generator-defined; deterministic.' )
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'Double Helix',
    'DNA-style helix structure (coupling tests)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object('type','double_helix','category','Pattern','generator',jsonb_build_object('turns',5,'radius_cm',12,'height_cm',60,'points_per_turn',48)),
    jsonb_build_object('units','cm','notes','Generator-defined.' )
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'Fractal Pattern',
    'Self-similar structure (multi-scale stability tests)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object('type','fractal','category','Pattern','generator',jsonb_build_object('kind','sierpinski','depth',4,'scale_cm',80)),
    jsonb_build_object('units','cm','notes','Generator-defined.' )
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  -- VOLUMES (explicit nodes)
  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    '4x4x4 Cube',
    '3D volumetric cube (64 nodes)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object(
      'type','cube','nx',4,'ny',4,'nz',4,'category','Volume',
      'nodes', (
        select jsonb_agg(jsonb_build_object(
          'id', format('C%02s_%02s_%02s', x, y, z),
          'x', x, 'y', y, 'z', z
        ) order by z, y, x)
        from generate_series(1,4) x cross join generate_series(1,4) y cross join generate_series(1,4) z
      )
    ),
    jsonb_build_object('units','cm','spacing',jsonb_build_object('x',8,'y',8,'z',8),'origin',jsonb_build_object('x',0,'y',0,'z',0))
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    '6x6x6 Cube',
    'Large volume cube (216 nodes)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object(
      'type','cube','nx',6,'ny',6,'nz',6,'category','Volume',
      'nodes', (
        select jsonb_agg(jsonb_build_object(
          'id', format('C%02s_%02s_%02s', x, y, z),
          'x', x, 'y', y, 'z', z
        ) order by z, y, x)
        from generate_series(1,6) x cross join generate_series(1,6) y cross join generate_series(1,6) z
      )
    ),
    jsonb_build_object('units','cm','spacing',jsonb_build_object('x',7,'y',7,'z',7),'origin',jsonb_build_object('x',0,'y',0,'z',0))
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  -- GEODESIC / TORUS / DIAMOND (generator style)
  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'Sphere (Geodesic)',
    'Spherical distribution (geodesic sampling)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object('type','geodesic_sphere','category','Geometric','generator',jsonb_build_object('subdivisions',2,'radius_cm',35,'nodes_target',128)),
    jsonb_build_object('units','cm','notes','Generator-defined geodesic points.' )
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'Torus',
    'Donut-shaped configuration (ring coupling tests)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object('type','torus','category','Geometric','generator',jsonb_build_object('major_radius_cm',35,'minor_radius_cm',12,'u_steps',24,'v_steps',12)),
    jsonb_build_object('units','cm','notes','Generator-defined torus mesh.' )
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'Diamond Lattice',
    'Crystal lattice pattern (structure resonance tests)',
    'PUBLISHED', true, 'RGSR', seed_owner, null,
    jsonb_build_object('type','diamond_lattice','category','Lattice','generator',jsonb_build_object('cells',3,'spacing_cm',10)),
    jsonb_build_object('units','cm','notes','Generator-defined lattice.' )
  ) on conflict on constraint geometry_sets_engine_name_lane_tpl_uq do nothing;

end$$;

-- ------------------------------------------------------------
-- 5) Seed Condition Profile templates (PUBLISHED)
--    Matches UI Saved Profiles panel (DRY_BASELINE_V1 / WATER_STATIC_20MM / HUMID_WARM_FLOW)
-- ------------------------------------------------------------
do $$
declare seed_owner uuid;
begin
  seed_owner := rgsr._seed_owner_any_user();
  if seed_owner is null then return; end if;

  insert into rgsr.condition_profiles(profile_name, profile_json, created_by, created_at, lane, is_template, engine_code, owner_id, lab_id, updated_at)
  values (
    'DRY_BASELINE_V1',
    jsonb_build_object(
      'temperature', jsonb_build_object('external_c',20.0,'internal_c',20.0,'water_c',0.0),
      'water_system', jsonb_build_object('volume_mm',0,'salinity_psu',0.0,'flow_lpm',0.0,'material_moisture_pct',0.0),
      'environment', jsonb_build_object('humidity_rh',40,'pressure_hpa',1013,'seasonal_profile','CONTROLLED'),
      'notes','Canonical dry baseline.'
    ),
    seed_owner, now(),
    'PUBLISHED', true, 'RGSR', seed_owner, null, now()
  ) on conflict on constraint condition_profiles_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.condition_profiles(profile_name, profile_json, created_by, created_at, lane, is_template, engine_code, owner_id, lab_id, updated_at)
  values (
    'WATER_STATIC_20MM',
    jsonb_build_object(
      'temperature', jsonb_build_object('external_c',20.0,'internal_c',20.0,'water_c',20.0),
      'water_system', jsonb_build_object('volume_mm',20,'salinity_psu',0.0,'flow_lpm',0.0,'material_moisture_pct',0.0),
      'environment', jsonb_build_object('humidity_rh',65,'pressure_hpa',1013,'seasonal_profile','CONTROLLED'),
      'notes','Static water at 20mm depth.'
    ),
    seed_owner, now(),
    'PUBLISHED', true, 'RGSR', seed_owner, null, now()
  ) on conflict on constraint condition_profiles_engine_name_lane_tpl_uq do nothing;

  insert into rgsr.condition_profiles(profile_name, profile_json, created_by, created_at, lane, is_template, engine_code, owner_id, lab_id, updated_at)
  values (
    'HUMID_WARM_FLOW',
    jsonb_build_object(
      'temperature', jsonb_build_object('external_c',22.0,'internal_c',22.0,'water_c',24.0),
      'water_system', jsonb_build_object('volume_mm',50,'salinity_psu',0.0,'flow_lpm',1.5,'material_moisture_pct',0.0),
      'environment', jsonb_build_object('humidity_rh',80,'pressure_hpa',1013,'seasonal_profile','SUMMER'),
      'notes','Humid warm flow profile for damping/coupling.'
    ),
    seed_owner, now(),
    'PUBLISHED', true, 'RGSR', seed_owner, null, now()
  ) on conflict on constraint condition_profiles_engine_name_lane_tpl_uq do nothing;
end$$;

-- ------------------------------------------------------------
-- 6) Grants: lock down security-definer RPC surface to authenticated
-- ------------------------------------------------------------
revoke all on function rgsr.set_lab_member_role(uuid, uuid, rgsr.rgsr_lab_role) from public;
revoke all on function rgsr.remove_lab_member(uuid, uuid) from public;
revoke all on function rgsr.leave_lab(uuid) from public;
revoke all on function rgsr.upsert_member_capability_override(uuid, uuid, text, boolean) from public;

grant execute on function rgsr.set_lab_member_role(uuid, uuid, rgsr.rgsr_lab_role) to authenticated;
grant execute on function rgsr.remove_lab_member(uuid, uuid) to authenticated;
grant execute on function rgsr.leave_lab(uuid) to authenticated;
grant execute on function rgsr.upsert_member_capability_override(uuid, uuid, text, boolean) to authenticated;

commit;

-- ============================================================
-- End migration
-- ============================================================
