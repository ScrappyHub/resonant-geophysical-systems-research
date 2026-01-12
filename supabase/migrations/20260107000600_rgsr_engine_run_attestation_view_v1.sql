begin;

create or replace view rgsr.v_engine_run_attestation as
select
  r.run_id,
  r.owner_uid,
  r.config_id,
  r.engine_kind,
  r.status,
  r.started_at,
  r.ended_at,
  r.tick_hz,
  r.dt_sec,
  r.max_steps,
  r.created_at,
  r.updated_at,

  r.seal_hash_sha256,
  r.replay_hash_sha256,
  r.hashes_match,

  coalesce(rr.readings_count, 0) as readings_count,
  rr.min_step_index,
  rr.max_step_index,
  rr.min_created_at as readings_first_at,
  rr.max_created_at as readings_last_at

from rgsr.engine_runs r
left join (
  select
    run_id,
    count(*)::bigint as readings_count,
    min(step_index) as min_step_index,
    max(step_index) as max_step_index,
    min(created_at) as min_created_at,
    max(created_at) as max_created_at
  from rgsr.engine_run_readings
  group by run_id
) rr
on rr.run_id = r.run_id;

comment on view rgsr.v_engine_run_attestation is
'DB-attested run summary: seal/replay hashes, generated hashes_match, and readings aggregate evidence for audit and verification.';

commit;
