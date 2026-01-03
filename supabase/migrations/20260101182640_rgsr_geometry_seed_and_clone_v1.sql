-- ============================================================
-- RGSR: Geometry Seeds + Clone + Library RPCs (V1)
-- Canonical: seed PUBLISHED templates (6x6 grid, pyramid)
-- Adds clone RPC so UI never copies JSON manually.
-- ============================================================

begin;

-- 1) Library RPC: list visible geometry (PRIVATE + LAB + PUBLISHED)
create or replace function rgsr.list_geometry_library(
  p_engine_code text default 'RGSR',
  p_only_templates boolean default false
)
returns table(
  geometry_id uuid,
  name text,
  description text,
  lane rgsr.rgsr_lane,
  is_template boolean,
  engine_code text,
  owner_id uuid,
  lab_id uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language sql stable as $$
  select
    g.geometry_id, g.name, g.description, g.lane, g.is_template, g.engine_code, g.owner_id, g.lab_id, g.created_at, g.updated_at
  from rgsr.geometry_sets g
  where g.engine_code = p_engine_code
    and (p_only_templates is false or g.is_template is true)
    and rgsr.can_read_geometry(g.lane, g.owner_id, g.lab_id)
  order by
    case g.lane when 'PUBLISHED' then 1 when 'LAB' then 2 when 'REVIEW' then 3 else 4 end,
    g.created_at desc;
$$;

-- 2) Get geometry details (returns JSON) - RLS still applies because it SELECTs from table
create or replace function rgsr.get_geometry_set(p_geometry_id uuid)
returns table(
  geometry_id uuid,
  name text,
  description text,
  lane rgsr.rgsr_lane,
  is_template boolean,
  engine_code text,
  owner_id uuid,
  lab_id uuid,
  geometry_json jsonb,
  dims_json jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language sql stable as $$
  select
    g.geometry_id, g.name, g.description, g.lane, g.is_template, g.engine_code, g.owner_id, g.lab_id, g.geometry_json, g.dims_json, g.created_at, g.updated_at
  from rgsr.geometry_sets g
  where g.geometry_id = p_geometry_id
    and rgsr.can_read_geometry(g.lane, g.owner_id, g.lab_id);
$$;

-- 3) Clone RPC (template -> my PRIVATE or LAB)
-- IMPORTANT: this is SECURITY DEFINER but enforces auth + target lane capability checks explicitly
create or replace function rgsr.clone_geometry_set(
  p_source_geometry_id uuid,
  p_new_name text,
  p_target_lane rgsr.rgsr_lane default 'PRIVATE',
  p_target_lab_id uuid default null,
  p_make_template boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
declare
  src record;
  new_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated' using errcode = 'insufficient_privilege';
  end if;

  select * into src
  from rgsr.geometry_sets g
  where g.geometry_id = p_source_geometry_id
    and rgsr.can_read_geometry(g.lane, g.owner_id, g.lab_id)
  limit 1;

  if not found then
    raise exception 'source geometry not found or not readable' using errcode = 'invalid_parameter_value';
  end if;

  if p_new_name is null or length(trim(p_new_name)) = 0 then
    raise exception 'new name is required' using errcode = 'invalid_parameter_value';
  end if;

  -- target lane rules
  if not rgsr.can_write_geometry_target(p_target_lane, p_target_lab_id) then
    raise exception 'not authorized for target lane' using errcode = 'insufficient_privilege';
  end if;

  -- if LAB/REVIEW lane, must be lab member
  if p_target_lane in ('LAB','REVIEW') then
    if p_target_lab_id is null then
      raise exception 'target lab required for LAB/REVIEW' using errcode = 'invalid_parameter_value';
    end if;
    if not rgsr.is_lab_member(p_target_lab_id) then
      raise exception 'not a member of target lab' using errcode = 'insufficient_privilege';
    end if;
  end if;

  -- template flag requires capability
  if p_make_template is true and not rgsr.has_capability('GEOMETRY_TEMPLATE') then
    raise exception 'not authorized to mark template' using errcode = 'insufficient_privilege';
  end if;

  insert into rgsr.geometry_sets(
    name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json
  ) values (
    trim(p_new_name), src.description, p_target_lane, p_make_template, src.engine_code, auth.uid(), p_target_lab_id, src.geometry_json, src.dims_json
  ) returning geometry_id into new_id;

  return new_id;
end;
$$;

-- 4) Canonical seeds: PUBLISHED templates (owner = first SYS_ADMIN user if exists, else auth.uid() at runtime is not available in migration)
-- We seed with a stable synthetic owner: use auth.users where email matches current project owner is unknown; so we use NULL owner? Not allowed.
-- Canonical approach: seed templates as PRIVATE owned by the first existing user_profile with SYS_ADMIN role, then allow promotion to PUBLISHED via UI.
-- If none exists yet, we still insert as PRIVATE using a placeholder function that finds any user_id.
create or replace function rgsr._seed_owner_any_user()
returns uuid language sql stable as $$
  select coalesce(
    (select up.user_id from rgsr.user_profiles up where up.role_id = 'SYS_ADMIN'::rgsr.rgsr_role_id order by up.created_at asc limit 1),
    (select up.user_id from rgsr.user_profiles up order by up.created_at asc limit 1)
  );
$$;

do $$
declare
  seed_owner uuid;
begin
  seed_owner := rgsr._seed_owner_any_user();
  if seed_owner is null then
    -- no users yet; skip seeds safely
    return;
  end if;

  -- 6x6 Grid template
  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'RGSR Grid 6x6 (Canonical)',
    'Canonical 6x6 node grid template for Phase A resonance capture.',
    'PUBLISHED',
    true,
    'RGSR',
    seed_owner,
    null,
    jsonb_build_object(
      'type','grid',
      'rows',6,
      'cols',6,
      'labels', jsonb_build_object(
        'x_axis','A-F',
        'y_axis','1-6'
      ),
      'nodes', (
        select jsonb_agg(jsonb_build_object(
          'id', format('%s%s', chr(64+xc), yc),
          'x', xc,
          'y', yc
        ) order by yc, xc)
        from generate_series(1,6) as yc
        cross join generate_series(1,6) as xc
      )
    ),
    jsonb_build_object(
      'units','cm',
      'spacing', jsonb_build_object('x',10,'y',10),
      'origin', jsonb_build_object('x',0,'y',0),
      'notes','Synthetic default dims; replace with chamber-calibrated dims when available.'
    )
  )
  on conflict do nothing;

  -- Pyramid template (symbolic layout)
  insert into rgsr.geometry_sets(name, description, lane, is_template, engine_code, owner_id, lab_id, geometry_json, dims_json)
  values (
    'RGSR Pyramid (Canonical)',
    'Canonical pyramid geometry placeholder (symbolic) for future chamber mapping.',
    'PUBLISHED',
    true,
    'RGSR',
    seed_owner,
    null,
    jsonb_build_object(
      'type','pyramid',
      'tiers',4,
      'nodes_per_tier', jsonb_build_array(1,4,9,16),
      'notes','Symbolic pyramid topology; wire real coordinates when instrumentation is defined.'
    ),
    jsonb_build_object(
      'units','cm',
      'bounds', jsonb_build_object('width',60,'depth',60,'height',50),
      'notes','Synthetic default dims; replace with real pyramid/chamber dims.'
    )
  )
  on conflict do nothing;
end$$;

commit;

-- ============================================================
-- End migration
-- ============================================================
