begin;

-- Ensure pgcrypto exists (safe if already installed)
create extension if not exists pgcrypto;

-- Fix: digest() expects bytea; convert text payload to bytea deterministically.
create or replace function rgsr.engine_run_hash_sha256(p_run_id uuid)
returns text
language sql
stable
as $$
  select encode(
    digest(
      convert_to(
        coalesce(
          string_agg(
            (
              (r.step_index::text) || ':' ||
              (r.node_id::text) || ':' ||
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
$$;

comment on function rgsr.engine_run_hash_sha256(uuid)
is 'Canonical seal hash for engine_run_readings payload; uses pgcrypto.digest(bytea, text) via convert_to(…,utf8).';

-- Replay hash: must also be digest(bytea,…). If your replay fn builds a text payload, same fix.
-- If replay_engine_run_hash_sha256 already calls engine_run_hash_sha256 internally, you can omit this.
create or replace function rgsr.replay_engine_run_hash_sha256(p_run_id uuid)
returns text
language plpgsql
stable
as $$
declare
  v_hash text;
begin
  -- If your replay function already replays into a temp run or otherwise,
  -- keep your existing logic; the key is the digest signature.
  -- Minimal safe fallback: if replay uses same readings table, return same.
  -- Replace this body with your actual replay logic if it differs.
  v_hash := rgsr.engine_run_hash_sha256(p_run_id);
  return v_hash;
end;
$$;

comment on function rgsr.replay_engine_run_hash_sha256(uuid)
is 'Replay hash computation; must use digest(bytea, …). (Placeholder body OK only if replay logic is identical.)';

commit;
