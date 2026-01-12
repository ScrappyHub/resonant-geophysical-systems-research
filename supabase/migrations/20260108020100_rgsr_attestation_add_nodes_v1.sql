begin;
drop view if exists rgsr.v_engine_run_attestation;
create view rgsr.v_engine_run_attestation as
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
  coalesce(rr.readings_count, 0::bigint) as readings_count,
  rr.min_step_index,
  rr.max_step_index,
  rr.min_created_at as readings_first_at,
  rr.max_created_at as readings_last_at,
  coalesce(pr.replay_runs_count, 0::bigint) as replay_runs_count,
  pr.last_replay_at,
  pr.last_replay_ok,
  pr.last_replay_hash_sha256,
  coalesce(nn.nodes_count, 0::bigint) as nodes_count,
  rgsr.engine_run_nodes_hash_sha256(r.run_id) as nodes_hash_sha256
from rgsr.engine_runs r
left join (
  select er.run_id, count(*) as readings_count,
         min(er.step_index) as min_step_index,
         max(er.step_index) as max_step_index,
         min(er.created_at) as min_created_at,
         max(er.created_at) as max_created_at
  from rgsr.engine_run_readings er
  group by er.run_id
) rr on rr.run_id = r.run_id
left join (
  select e.run_id, count(*) as replay_runs_count,
         max(e.ended_at) as last_replay_at,
         (array_agg(e.ok order by e.ended_at desc nulls last, e.started_at desc))[1] as last_replay_ok,
         (array_agg(e.replay_hash_sha256 order by e.ended_at desc nulls last, e.started_at desc))[1] as last_replay_hash_sha256
  from rgsr.engine_run_replay_runs e
  group by e.run_id
) pr on pr.run_id = r.run_id
left join (
  select x.run_id, count(*) as nodes_count
  from (
    select s.run_id, s.node_id from rgsr.engine_run_nodes_snapshot s
    union all
    select n.run_id, n.node_id
    from rgsr.engine_run_nodes n
    where not exists (
      select 1 from rgsr.engine_run_nodes_snapshot s2 where s2.run_id = n.run_id
    )
  ) x
  group by x.run_id
) nn on nn.run_id = r.run_id;

comment on view rgsr.v_engine_run_attestation is
'Attestation surface for a run: seal + replay invariants, readings proof, replay audit rollups, and snapshot-aware node set proof.';

commit;
