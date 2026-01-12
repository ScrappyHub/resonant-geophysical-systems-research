begin;

-- ============================================================
-- RGSR: MINIMUM SEAL+REPLAY SURFACE (CANONICAL)
-- Ensures these exist in schema rgsr:
--   - rgsr.engine_run_hash_sha256(uuid)
--   - rgsr.replay_engine_run_hash_sha256(uuid)   (placeholder for now)
--   - rgsr.finalize_engine_run(uuid)
-- Also ensures engine_runs status constraint allows 'sealed'.
-- ============================================================

-- 1) crypto
create extension if not exists pgcrypto;

-- 2) Ensure status constraint allows sealed (idempotent)
do $$
declare
  v_def text;
begin
  select pg_get_constraintdef(c.oid)
    into v_def
  from pg_constraint c
  where c.conname = 'engine_runs_status_chk'
    and c.conrelid = 'rgsr.engine_runs'::regclass;

  if v_def is null then
    -- If the constraint doesn't exist, do nothing here (your schema may enforce via enum/domain instead).
    raise notice 'engine_runs_status_chk not found; skipping constraint patch';
    return;
  end if;

  if position('sealed' in v_def) = 0 then
    -- Drop/recreate with sealed added
    execute 'alter table rgsr.engine_runs drop constraint engine_runs_status_chk';

    execute $q$
      alter table rgsr.engine_runs
      add constraint engine_runs_status_chk
      check (status = any (array[
        'created'::text,
        'running'::text,
        'paused'::text,
        'completed'::text,
        'failed'::text,
        'sealed'::text
      ]))
    $q$;

    raise notice 'engine_runs_status_chk updated to allow sealed';
  else
    raise notice 'engine_runs_status_chk already allows sealed';
  end if;
end
$$;

-- 3) Canonical seal hash (deterministic over stored readings)
create or replace function rgsr.engine_run_hash_sha256(p_run_id uuid)
returns text
language sql
stable
as $function$
  select encode(
    extensions.digest(
      convert_to(
        coalesce(
          string_agg(
            (
              (r.step_index::text) || ':' ||
              (r.node_id::text)    || ':' ||
              coalesce(r.t_sim_sec::text, '') || ':' ||
              coalesce(r.readings::text, '')
            ),
            '|' order by r.step_index asc, r.node_id asc, r.reading_id asc
          ),
          ''
        ),
        'utf8'
      ),
      'sha256'
    ),
    'hex'
  )
  from rgsr.engine_run_readings r
  where r.run_id = p_run_id;
$function$;

comment on function rgsr.engine_run_hash_sha256(uuid) is
'Canonical seal hash over persisted engine_run_readings ordered by step_index,node_id,reading_id; sha256 hex.';

-- 4) Replay hash placeholder (REAL replay comes next; this just unblocks harness)
create or replace function rgsr.replay_engine_run_hash_sha256(p_run_id uuid)
returns text
language sql
stable
as $function$
  select rgsr.engine_run_hash_sha256(p_run_id);
$function$;

comment on function rgsr.replay_engine_run_hash_sha256(uuid) is
'PLACEHOLDER: returns seal hash; replaced by REAL replay engine in next migration set.';

-- 5) Finalize: compute + persist seal/replay, set status=sealed
create or replace function rgsr.finalize_engine_run(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path to 'rgsr','public'
as $function$
declare
  v_seal   text;
  v_replay text;
begin
  if p_run_id is null then
    raise exception 'RUN_ID_REQUIRED';
  end if;

  v_seal   := rgsr.engine_run_hash_sha256(p_run_id);
  v_replay := rgsr.replay_engine_run_hash_sha256(p_run_id);

  if v_seal is null or v_replay is null then
    raise exception 'SEAL_OR_REPLAY_HASH_NULL for run_id=%', p_run_id;
  end if;

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
$function$;

comment on function rgsr.finalize_engine_run(uuid) is
'Computes seal+replay hashes and finalizes run as sealed; hashes_match is generated elsewhere (if present).';

commit;
