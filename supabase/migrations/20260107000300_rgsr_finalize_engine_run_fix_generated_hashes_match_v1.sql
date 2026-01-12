begin;

create or replace function rgsr.finalize_engine_run(p_run_id uuid)
returns void
language plpgsql
as $$
declare
  v_seal   text;
  v_replay text;
begin
  -- compute both hashes
  v_seal   := rgsr.engine_run_hash_sha256(p_run_id);
  v_replay := rgsr.replay_engine_run_hash_sha256(p_run_id);

  if v_seal is null or v_seal = '' then
    raise exception 'SEAL_HASH_EMPTY run_id=%', p_run_id;
  end if;

  if v_replay is null or v_replay = '' then
    raise exception 'REPLAY_HASH_EMPTY run_id=%', p_run_id;
  end if;

  -- IMPORTANT: hashes_match is a GENERATED column. Do not set it.
  update rgsr.engine_runs
     set seal_hash_sha256   = v_seal,
         replay_hash_sha256 = v_replay,
         ended_at           = coalesce(ended_at, now()),
         updated_at         = now()
   where run_id = p_run_id;

  if not found then
    raise exception 'ENGINE_RUN_NOT_FOUND run_id=%', p_run_id;
  end if;
end;
$$;

comment on function rgsr.finalize_engine_run(uuid) is
'Computes seal + replay hashes and stores them on rgsr.engine_runs. hashes_match is generated and not written explicitly.';

commit;
