begin;

create or replace function rgsr.replay_engine_run_hash_sha256(p_run_id uuid)
returns text
language plpgsql
stable
security definer
set search_path to 'rgsr','public','extensions'
as $$
declare
  v_cfg uuid;
  v_owner uuid;
  v_dt numeric;
  v_engine_kind text;

  v_steps int;
  v_replay_run uuid;
  v_hash text;
begin
  if p_run_id is null then
    raise exception 'RUN_ID_REQUIRED';
  end if;

  select er.config_id, er.owner_uid, er.dt_sec, er.engine_kind
    into v_cfg, v_owner, v_dt, v_engine_kind
  from rgsr.engine_runs er
  where er.run_id = p_run_id;

  if v_cfg is null then
    raise exception 'RUN_NOT_FOUND_OR_CONFIG_NULL: %', p_run_id;
  end if;
  if v_owner is null then
    raise exception 'RUN_OWNER_NULL: %', p_run_id;
  end if;

  -- Steps = max(step_index)+1 (because step_index is 0-based in most sims)
  select coalesce(max(r.step_index), -1) + 1
    into v_steps
  from rgsr.engine_run_readings r
  where r.run_id = p_run_id;

  if v_steps <= 0 then
    raise exception 'NO_READINGS_TO_REPLAY: run_id=%', p_run_id;
  end if;

  -- NOTE: today we only have rgsr.step_engine_run_2d available.
  -- This is NOT a placeholder: it is a strict enforcement gate.
  -- If you add other engine kinds later, you must add their replay branches here.
  if v_engine_kind is not null and v_engine_kind not in ('2D','DEMO_2D','RGSR_2D') then
    raise exception 'UNSUPPORTED_ENGINE_KIND_FOR_REPLAY: % (run_id=%)', v_engine_kind, p_run_id;
  end if;

  v_replay_run := gen_random_uuid();

  insert into rgsr.engine_runs(
    run_id, owner_uid, config_id,
    engine_kind, status,
    dt_sec, stats, created_at, updated_at
  )
  values (
    v_replay_run, v_owner, v_cfg,
    v_engine_kind, 'replay',
    v_dt, '{}'::jsonb, now(), now()
  );

  -- Actual replay: step the new run the same # of steps
  perform rgsr.step_engine_run_2d(v_replay_run, v_steps);

  -- Hash replay output from replay run readings
  v_hash := rgsr.engine_run_hash_sha256(v_replay_run);

  if v_hash is null then
    raise exception 'REPLAY_HASH_NULL: replay_run_id=% original_run_id=%', v_replay_run, p_run_id;
  end if;

  -- Cleanup replay artifacts (keeps DB clean; audit relies on persisted hashes on original run)
  delete from rgsr.engine_run_readings where run_id = v_replay_run;
  delete from rgsr.engine_runs where run_id = v_replay_run;

  return v_hash;

exception when others then
  -- best-effort cleanup
  begin
    delete from rgsr.engine_run_readings where run_id = v_replay_run;
    delete from rgsr.engine_runs where run_id = v_replay_run;
  exception when others then
    null;
  end;
  raise;
end;
$$;

comment on function rgsr.replay_engine_run_hash_sha256(uuid)
is 'Audit-grade replay hash: creates a fresh replay run from same config/seed, steps same number of steps as original, hashes replay readings, then cleans up.';

commit;
