-- CORE V1: Seal + Replay Attestation (Canonical)
-- Requires: pgcrypto

begin;

-- Ensure pgcrypto exists (safe no-op if already installed)
create extension if not exists pgcrypto;

-- 1) Canonical hash over engine_run_readings for a given run.
--    IMPORTANT: exclude created_at from payload (non-deterministic).
create or replace function rgsr.engine_run_hash_sha256(p_run_id uuid)
returns text
language sql
stable
as $$
  select encode(
    digest(
      coalesce(
        string_agg(
          (
            -- canonical row payload (text)
            (r.step_index::text) || ':' ||
            (r.node_id::text) || ':' ||
            coalesce(r.t_sim_sec::text, '') || ':' ||
            coalesce(r.readings::text, '')  -- jsonb::text is canonicalized in Postgres
          ),
          '|' order by r.step_index asc, r.node_id asc, r.reading_id asc
        ),
        ''
      ),
      'sha256'
    ),
    'hex'
  )
  from rgsr.engine_run_readings r
  where r.run_id = p_run_id;
$$;

comment on function rgsr.engine_run_hash_sha256(uuid) is
'Canonical SHA-256 hash of rgsr.engine_run_readings for a run. Payload excludes created_at. Ordering: step_index, node_id, reading_id.';

-- 2) Replay hash: build a fresh run and step to same computed step count, then hash.
--    We use the sealed run’s observed max(step_index) as the replay target.
create or replace function rgsr.replay_engine_run_hash_sha256(p_run_id uuid)
returns text
language plpgsql
volatile
as $$
declare
  v_owner uuid;
  v_cfg   uuid;
  v_dt    numeric;
  v_steps int;
  v_replay_run uuid;
  v_hash text;
begin
  -- load canonical inputs
  select owner_uid, config_id, dt_sec
    into v_owner, v_cfg, v_dt
  from rgsr.engine_runs
  where run_id = p_run_id;

  if v_owner is null or v_cfg is null then
    raise exception 'RUN_NOT_FOUND_OR_MISSING_FIELDS run_id=% owner=% cfg=%', p_run_id, v_owner, v_cfg;
  end if;

  -- determine target steps from existing readings
  select coalesce(max(step_index), 0)
    into v_steps
  from rgsr.engine_run_readings
  where run_id = p_run_id;

  if v_steps <= 0 then
    raise exception 'NO_READINGS_TO_REPLAY run_id=%', p_run_id;
  end if;

  -- create replay run
  insert into rgsr.engine_runs(run_id, owner_uid, config_id, dt_sec, stats, created_at, updated_at)
  values (gen_random_uuid(), v_owner, v_cfg, coalesce(v_dt, 0.01), '{}'::jsonb, now(), now())
  returning run_id into v_replay_run;

  -- step replay run to same step count
  perform rgsr.step_engine_run_2d(v_replay_run, v_steps);

  -- hash replay run readings
  v_hash := rgsr.engine_run_hash_sha256(v_replay_run);

  if v_hash is null or v_hash = '' then
    raise exception 'REPLAY_HASH_EMPTY replay_run_id=%', v_replay_run;
  end if;

  return v_hash;
end;
$$;

comment on function rgsr.replay_engine_run_hash_sha256(uuid) is
'Replays a run deterministically by creating a fresh run with same owner+config+dt and stepping to max(step_index) of the original run; returns canonical hash.';

-- 3) Finalize: compute seal + replay + compare; persist on engine_runs.
create or replace function rgsr.finalize_engine_run(p_run_id uuid)
returns void
language plpgsql
volatile
as $$
declare
  v_seal text;
  v_replay text;
  v_match boolean;
begin
  -- compute seal from current readings
  v_seal := rgsr.engine_run_hash_sha256(p_run_id);

  if v_seal is null or v_seal = '' then
    raise exception 'SEAL_HASH_EMPTY run_id=%', p_run_id;
  end if;

  -- compute replay hash
  v_replay := rgsr.replay_engine_run_hash_sha256(p_run_id);

  v_match := (v_seal = v_replay);

  update rgsr.engine_runs
     set seal_hash_sha256   = v_seal,
         replay_hash_sha256 = v_replay,
         hashes_match       = v_match,
         ended_at           = coalesce(ended_at, now()),
         updated_at         = now()
   where run_id = p_run_id;

  if not found then
    raise exception 'RUN_NOT_FOUND run_id=%', p_run_id;
  end if;

  if v_match is not true then
    raise exception 'SEAL_REPLAY_MISMATCH run_id=% seal=% replay=%', p_run_id, v_seal, v_replay;
  end if;
end;
$$;

comment on function rgsr.finalize_engine_run(uuid) is
'Computes seal hash + replay hash for a run, persists both, sets hashes_match, and errors if mismatch.';

commit;
