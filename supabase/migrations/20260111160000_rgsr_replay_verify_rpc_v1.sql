-- 20260111160000_rgsr_replay_verify_rpc_v1.sql
-- CANONICAL: single replay verification API for sealed runs
-- Policy: deterministic, structured failures; NEVER silently "pass" without checking.
-- Note: This RPC must be safe to call from tooling/CI. It must not mutate state.

begin;

create schema if not exists rgsr;

create or replace function rgsr.replay_verify_engine_run(p_engine_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, rgsr
as $$
declare
  v_exists boolean := false;

  v_status text;
  v_stored_seal text;
  v_stored_replay text;

  v_created_at timestamptz;
  v_updated_at timestamptz;

  v_computed text;

  v_failures jsonb := '[]'::jsonb;
  v_ok boolean := true;
begin
  select
    true,
    er.status,
    er.seal_hash_sha256,
    er.replay_hash_sha256,
    er.created_at,
    er.updated_at
  into
    v_exists,
    v_status,
    v_stored_seal,
    v_stored_replay,
    v_created_at,
    v_updated_at
  from rgsr.engine_runs er
  where er.run_id = p_engine_run_id;

  if not v_exists then
    return jsonb_build_object(
      'ok', false,
      'failures', jsonb_build_array(jsonb_build_object(
        'code','run_not_found',
        'message','engine_run_id not found',
        'engine_run_id', p_engine_run_id
      )),
      'computed_hash', null,
      'stored_hash', null,
      'replay_hash', null,
      'timestamps', jsonb_build_object(
        'verified_at', now(),
        'created_at', null,
        'updated_at', null
      )
    );
  end if;

  -- canonical expectation: verification targets sealed runs
  if v_status is distinct from 'sealed' then
    v_ok := false;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code','not_sealed',
      'message','run status is not sealed',
      'status', v_status
    ));
  end if;

  if v_stored_seal is null then
    v_ok := false;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code','missing_seal_hash',
      'message','seal_hash_sha256 is null'
    ));
  end if;

  -- non-mutating replay computation from current DB state
  v_computed := rgsr.replay_engine_run_hash_sha256(p_engine_run_id);

  if v_computed is null then
    v_ok := false;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code','computed_hash_null',
      'message','replay_engine_run_hash_sha256 returned null'
    ));
  end if;

  -- compare computed to stored seal hash
  if v_stored_seal is not null and v_computed is not null and v_stored_seal <> v_computed then
    v_ok := false;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code','seal_vs_computed_mismatch',
      'message','stored seal hash does not match computed replay hash',
      'stored_seal', v_stored_seal,
      'computed', v_computed
    ));
  end if;

  -- if stored replay hash exists, compare it too
  if v_stored_replay is not null and v_computed is not null and v_stored_replay <> v_computed then
    v_ok := false;
    v_failures := v_failures || jsonb_build_array(jsonb_build_object(
      'code','stored_replay_vs_computed_mismatch',
      'message','stored replay hash does not match computed replay hash',
      'stored_replay', v_stored_replay,
      'computed', v_computed
    ));
  end if;

  return jsonb_build_object(
    'ok', v_ok,
    'failures', v_failures,
    'computed_hash', v_computed,
    'stored_hash', v_stored_seal,
    'replay_hash', v_stored_replay,
    'timestamps', jsonb_build_object(
      'verified_at', now(),
      'created_at', v_created_at,
      'updated_at', v_updated_at
    )
  );
end;
$$;

-- ============================================================
-- CANONICAL PERMISSIONS (PRODUCTION POSTURE)
-- service_role only (plus optional supabase_admin if present)
-- ============================================================

revoke all on function rgsr.replay_verify_engine_run(uuid) from public;
revoke all on function rgsr.replay_verify_engine_run(uuid) from anon;
revoke all on function rgsr.replay_verify_engine_run(uuid) from authenticated;

grant execute on function rgsr.replay_verify_engine_run(uuid) to service_role;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_admin') then
    grant execute on function rgsr.replay_verify_engine_run(uuid) to supabase_admin;
  end if;
exception when others then
  null;
end $$;

commit;
