-- 20260112120000_rgsr_ab_compare_v1.sql
-- CANONICAL: deterministic A/B comparison API for engine runs (non-mutating)
-- Policy:
--   - MUST NOT mutate state
--   - MUST be deterministic: same DB state => same output JSON
--   - MUST provide structured failures
--   - MUST be callable only by service_role in production posture

begin;

create schema if not exists rgsr;

-- ============================================================
-- A/B CASE TABLES (optional but recommended for traceability)
-- ============================================================

create table if not exists rgsr.ab_cases (
  case_id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by_uid uuid null,
  label text null,
  notes text null,
  meta jsonb not null default '{}'::jsonb
);

create table if not exists rgsr.ab_case_pairs (
  pair_id uuid primary key default gen_random_uuid(),
  case_id uuid not null references rgsr.ab_cases(case_id) on delete cascade,
  created_at timestamptz not null default now(),

  a_run_id uuid not null references rgsr.engine_runs(run_id) on delete restrict,
  b_run_id uuid not null references rgsr.engine_runs(run_id) on delete restrict,

  -- deterministic identity for the pair (helps caching, UI, CI)
  pair_key text generated always as (
    encode(digest(a_run_id::text || '|' || b_run_id::text, 'sha256'),'hex')
  ) stored
);

create index if not exists ix_ab_case_pairs_case on rgsr.ab_case_pairs(case_id);
create unique index if not exists ux_ab_case_pairs_case_ab on rgsr.ab_case_pairs(case_id, a_run_id, b_run_id);

-- ============================================================
-- RPC: compare two engine_run_ids
-- ============================================================
-- Output JSON layout:
-- {
--   ok: bool,
--   failures: [...],
--   a: {run_id, status, seal_hash, replay_hash, computed_hash},
--   b: { ... },
--   comparison: {
--     seal_equal: bool,
--     replay_equal: bool,
--     computed_equal: bool,
--     computed_a_equals_seal_a: bool,
--     computed_b_equals_seal_b: bool,
--     derived: {
--       a_vs_b_hash_equal: bool
--     }
--   },
--   timestamps: { compared_at, a_created_at, b_created_at }
-- }
create or replace function rgsr.ab_compare_engine_runs(p_a_run_id uuid, p_b_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, rgsr
as $$
declare
  a_exists boolean := false;
  b_exists boolean := false;

  a_status text;
  a_seal text;
  a_replay text;
  a_created_at timestamptz;

  b_status text;
  b_seal text;
  b_replay text;
  b_created_at timestamptz;

  a_computed text;
  b_computed text;

  v_ok boolean := true;
  v_failures jsonb := '[]'::jsonb;
begin
  -- load A
  select true, er.status, er.seal_hash_sha256, er.replay_hash_sha256, er.created_at
  into a_exists, a_status, a_seal, a_replay, a_created_at
  from rgsr.engine_runs er
  where er.run_id = p_a_run_id;

  -- load B
  select true, er.status, er.seal_hash_sha256, er.replay_hash_sha256, er.created_at
  into b_exists, b_status, b_seal, b_replay, b_created_at
  from rgsr.engine_runs er
  where er.run_id = p_b_run_id;

  if not a_exists then
    v_ok := false;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code','a_run_not_found',
      'message','A run_id not found',
      'run_id', p_a_run_id
    ));
  end if;

  if not b_exists then
    v_ok := false;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code','b_run_not_found',
      'message','B run_id not found',
      'run_id', p_b_run_id
    ));
  end if;

  if not v_ok then
    return jsonb_build_object(
      'ok', false,
      'failures', v_failures,
      'a', null,
      'b', null,
      'comparison', null,
      'timestamps', jsonb_build_object('compared_at', now())
    );
  end if;

  -- A must be sealed to be comparable (policy; change if you want)
  if a_status is distinct from 'sealed' then
    v_ok := false;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code','a_not_sealed',
      'message','A run status is not sealed',
      'status', a_status
    ));
  end if;

  if b_status is distinct from 'sealed' then
    v_ok := false;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code','b_not_sealed',
      'message','B run status is not sealed',
      'status', b_status
    ));
  end if;

  -- computed hashes from current DB state (non-mutating)
  a_computed := rgsr.replay_engine_run_hash_sha256(p_a_run_id);
  b_computed := rgsr.replay_engine_run_hash_sha256(p_b_run_id);

  if a_computed is null then
    v_ok := false;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code','a_computed_null',
      'message','computed replay hash for A is null'
    ));
  end if;

  if b_computed is null then
    v_ok := false;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code','b_computed_null',
      'message','computed replay hash for B is null'
    ));
  end if;

  return jsonb_build_object(
    'ok', v_ok,
    'failures', v_failures,

    'a', jsonb_build_object(
      'run_id', p_a_run_id,
      'status', a_status,
      'seal_hash', a_seal,
      'replay_hash', a_replay,
      'computed_hash', a_computed
    ),

    'b', jsonb_build_object(
      'run_id', p_b_run_id,
      'status', b_status,
      'seal_hash', b_seal,
      'replay_hash', b_replay,
      'computed_hash', b_computed
    ),

    'comparison', jsonb_build_object(
      'seal_equal', (a_seal is not null and b_seal is not null and a_seal = b_seal),
      'replay_equal', (a_replay is not null and b_replay is not null and a_replay = b_replay),
      'computed_equal', (a_computed is not null and b_computed is not null and a_computed = b_computed),

      'computed_a_equals_seal_a', (a_seal is not null and a_computed is not null and a_seal = a_computed),
      'computed_b_equals_seal_b', (b_seal is not null and b_computed is not null and b_seal = b_computed),

      'derived', jsonb_build_object(
        'a_vs_b_hash_equal', (a_computed is not null and b_computed is not null and a_computed = b_computed)
      )
    ),

    'timestamps', jsonb_build_object(
      'compared_at', now(),
      'a_created_at', a_created_at,
      'b_created_at', b_created_at
    )
  );
end;
$$;

-- ============================================================
-- CANONICAL PERMISSIONS (PRODUCTION POSTURE)
-- service_role only (plus optional supabase_admin if present)
-- ============================================================

revoke all on function rgsr.ab_compare_engine_runs(uuid, uuid) from public;
revoke all on function rgsr.ab_compare_engine_runs(uuid, uuid) from anon;
revoke all on function rgsr.ab_compare_engine_runs(uuid, uuid) from authenticated;

grant execute on function rgsr.ab_compare_engine_runs(uuid, uuid) to service_role;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_admin') then
    grant execute on function rgsr.ab_compare_engine_runs(uuid, uuid) to supabase_admin;
  end if;
exception when others then
  null;
end $$;

commit;
