-- 20260107034500_rgsr_seed_demo_2d_engine_config_local_v1.sql
-- CANONICAL LOCAL SEED (validator-safe + column-type-safe):
-- Ensures a known DEMO_2D engine_config exists so rgsr.create_engine_run() can succeed after fresh db resets.
-- Idempotent + FK-safe + constraint-safe.
-- IMPORTANT: Supabase migrations must be pure SQL (no \pset / \set).

do $$
declare
  v_config_id uuid := 'a7250498-6d20-4422-8f20-46650b615198'::uuid;
  v_owner_uid  uuid := 'd4ca5da1-b30a-44af-8b7e-2fd0fbc0bd2d'::uuid;

  -- schema_version column may exist and may not be TEXT in your schema (yours is integer-ish).
  v_sv_data_type text;
  v_sv_udt_name  text;
  v_sv_sql_value text;   -- already-escaped SQL literal or numeric string
  v_has_sv_col   boolean := false;

  v_config jsonb;
  v_sql text;
begin
  -- ============================================================
  -- 0) Ensure auth user exists (FK spine)
  -- ============================================================
  insert into auth.users (
    id, aud, role, email,
    raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at,
    is_sso_user, is_anonymous
  )
  select
    v_owner_uid,
    'authenticated',
    'authenticated',
    'dev@local.test',
    '{}'::jsonb,
    '{}'::jsonb,
    now(),
    now(),
    false,
    false
  where not exists (
    select 1 from auth.users where id = v_owner_uid
  );

  -- ============================================================
  -- 1) Build a validator-safe DEMO_2D config JSON
  --    (matches the errors you saw: domains object, geometry.kind,
  --     excitation required fields, nodes[*].position.z)
  -- ============================================================
  v_config :=
    jsonb_build_object(
      'schema_version', 'rgsr.engine_config.v1',
      'engine_kind',    '2D',
      'label',          'DEMO_2D (local seeded)',
      'notes',          'Canonical local seed so create_engine_run() has a validator-safe config after db reset.',

      'domains', jsonb_build_object('demo', true),

      'geometry', jsonb_build_object('kind', 'PLANE_2D'),

      'excitation', jsonb_build_object(
        'frequency_hz',     1.0,
        'amplitude',        1.0,
        'waveform',         'SINE',
        'phase_offset_deg', 0.0,
        'duty_cycle',       0.5
      ),

      'materials',       '{}'::jsonb,
      'water',           '{}'::jsonb,
      'thermal',         '{}'::jsonb,
      'atmosphere',      '{}'::jsonb,
      'electromagnetic', '{}'::jsonb,

      'nodes', jsonb_build_array(
        jsonb_build_object(
          'node_id',  'demo_node_1',
          'position', jsonb_build_object('x', 0,  'y', 0, 'z', 0),
          'measures', jsonb_build_array('pressure','shear'),
          'metadata', jsonb_build_object('label','Demo Node 1')
        ),
        jsonb_build_object(
          'node_id',  'demo_node_2',
          'position', jsonb_build_object('x', 10, 'y', 0, 'z', 0),
          'measures', jsonb_build_array('pressure'),
          'metadata', jsonb_build_object('label','Demo Node 2')
        )
      )
    );

  -- ============================================================
  -- 2) Detect schema_version column presence + type (avoid 22P02)
  -- ============================================================
  select c.data_type, c.udt_name
    into v_sv_data_type, v_sv_udt_name
  from information_schema.columns c
  where c.table_schema = 'rgsr'
    and c.table_name   = 'engine_configs'
    and c.column_name  = 'schema_version';

  if v_sv_data_type is not null then
    v_has_sv_col := true;

    -- If schema_version is numeric-ish, use 1. If text-ish, use the string.
    if v_sv_data_type in ('smallint','integer','bigint')
       or v_sv_udt_name in ('int2','int4','int8') then
      v_sv_sql_value := '1';
    else
      -- covers text, varchar, etc.
      v_sv_sql_value := quote_literal('rgsr.engine_config.v1');
    end if;
  end if;

  -- ============================================================
  -- 3) Insert config if missing (dynamic SQL to handle schema_version type)
  -- ============================================================
  if not exists (
    select 1 from rgsr.engine_configs where config_id = v_config_id
  ) then
    if v_has_sv_col then
      v_sql :=
        'insert into rgsr.engine_configs (config_id, owner_uid, config_kind, is_public, schema_version, config)
         values ($1, $2, $3, $4, ' || v_sv_sql_value || ', $5)';
      execute v_sql
        using v_config_id, v_owner_uid, 'DEMO_2D', true, v_config;
    else
      v_sql :=
        'insert into rgsr.engine_configs (config_id, owner_uid, config_kind, is_public, config)
         values ($1, $2, $3, $4, $5)';
      execute v_sql
        using v_config_id, v_owner_uid, 'DEMO_2D', true, v_config;
    end if;
  end if;
end
$$;

-- ============================================================
-- Evidence (prints in migration output)
-- ============================================================
select
  config_id,
  owner_uid,
  is_public,
  config_kind,
  created_at,
  updated_at
from rgsr.engine_configs
where config_id = 'a7250498-6d20-4422-8f20-46650b615198'::uuid;
