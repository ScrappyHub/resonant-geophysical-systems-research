-- RGSR Replay Determinism Test (SQL-only, CI-safe, NEVER SKIPS)
-- Creates its own run, seeds nodes, steps, seals, replays, then asserts:
--   - seal_hash_sha256 IS NOT NULL
--   - replay_hash_sha256 IS NOT NULL
--   - hashes_match = true
-- Fails hard if any prerequisite is missing.

do $$
declare
  v_user   uuid;
  v_config uuid;
  v_run    uuid;
  v_replay uuid;

  v_seed jsonb;
  v_step jsonb;
  v_rows int;

  v_seal text;
  v_replay_hash text;
  v_match boolean;
begin
  -- 1) pick a config
  select config_id into v_config
  from rgsr.engine_configs
  order by created_at desc nulls last
  limit 1;

  if v_config is null then
    raise exception 'RGSR determinism test: FAIL - no rgsr.engine_configs found';
  end if;

  -- 2) create/get local owner
  v_user := rgsr._seed_owner_any_user();
  if v_user is null then
    raise exception 'RGSR determinism test: FAIL - rgsr._seed_owner_any_user() returned null';
  end if;

  -- 3) create run
  v_run := gen_random_uuid();
  insert into rgsr.engine_runs(
    run_id, owner_uid, config_id, engine_kind, status,
    tick_hz, dt_sec, max_steps, state, stats,
    created_at, updated_at
  )
  values (
    v_run, v_user, v_config, '2D', 'created',
    60, 0.0166666667, 120, '{}'::jsonb, '{}'::jsonb,
    now(), now()
  );

  -- 4) seed nodes from config (must succeed)
  v_seed := rgsr.seed_run_nodes_from_config(v_run);
  if coalesce(v_seed->>'ok','false') <> 'true' then
    raise exception 'RGSR determinism test: FAIL - seed_run_nodes_from_config returned %', v_seed;
  end if;

  select count(*) into v_rows
  from rgsr.engine_run_nodes
  where run_id = v_run;

  if v_rows <= 0 then
    raise exception 'RGSR determinism test: FAIL - seeded 0 nodes for run=%', v_run;
  end if;

  -- 5) step engine to generate readings (must succeed)
  v_step := rgsr.step_engine_run_2d(v_run, 10);
  if coalesce(v_step->>'ok','false') <> 'true' then
    raise exception 'RGSR determinism test: FAIL - step_engine_run_2d returned %', v_step;
  end if;

  -- 6) snapshot nodes (optional but we want it exercised)
  perform rgsr.snapshot_engine_run_nodes(v_run);

  -- 7) finalize (seal)
  perform rgsr.finalize_engine_run(v_run);

  -- 8) replay (must write evidence + replay hash)
  v_replay := rgsr.run_engine_run_replay(
    v_run,
    jsonb_build_object('source','ci_determinism_test','ts',now())
  );

  if v_replay is null then
    raise exception 'RGSR determinism test: FAIL - run_engine_run_replay returned null for run=%', v_run;
  end if;

  -- 9) assert determinism (for this run, not “any run in the DB”)
  select seal_hash_sha256, replay_hash_sha256, hashes_match
    into v_seal, v_replay_hash, v_match
  from rgsr.engine_runs
  where run_id = v_run;

  if v_seal is null or v_replay_hash is null then
    raise exception 'RGSR determinism test: FAIL - missing hashes for run=% (seal=% replay=%)', v_run, v_seal, v_replay_hash;
  end if;

  if v_match is distinct from true then
    raise exception 'RGSR determinism test: FAIL - hashes do not match for run=% (seal=% replay=% match=%)',
      v_run, v_seal, v_replay_hash, v_match;
  end if;

  raise notice 'RGSR determinism test: PASS run=% seal=% replay=%', v_run, v_seal, v_replay_hash;
end
$$;
