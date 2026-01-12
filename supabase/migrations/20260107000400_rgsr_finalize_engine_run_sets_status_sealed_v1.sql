begin;

-- finalize_engine_run must:
--  - compute seal hash
--  - compute replay hash
--  - persist both hashes
--  - set ended_at if missing
--  - set status='sealed'
--  - NEVER write hashes_match (generated column)

create or replace function rgsr.finalize_engine_run(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path = rgsr, public
as $fn$
declare
  v_seal   text;
  v_replay text;
begin
  if p_run_id is null then
    raise exception 'RUN_ID_REQUIRED';
  end if;

  -- Compute seal + replay
  v_seal   := rgsr.engine_run_hash_sha256(p_run_id);
  v_replay := rgsr.replay_engine_run_hash_sha256(p_run_id);

  if v_seal is null or v_replay is null then
    raise exception 'SEAL_OR_REPLAY_HASH_NULL for run_id=%', p_run_id;
  end if;

  -- Persist (DO NOT touch hashes_match - it is generated)
  update rgsr.engine_runs
     set seal_hash_sha256   = v_seal,
         replay_hash_sha256 = v_replay,
         ended_at           = coalesce(ended_at, now()),
         status             = 'sealed',
         updated_at         = now()
   where run_id = p_run_id;

  if not found then
    raise exception 'RUN_NOT_FOUND: %', p_run_id;
  end if;
end
$fn$;

comment on function rgsr.finalize_engine_run(uuid) is
'Finalize an engine run by persisting seal hash + replay hash, stamping ended_at, and setting status=sealed. Never updates hashes_match (generated).';

commit;
