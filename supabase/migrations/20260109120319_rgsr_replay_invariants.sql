begin;

-- RGSR: Replay determinism invariants (schema-correct)
-- Asserts (seal_hash_sha256 == replay_hash_sha256) per run, when both present.

create or replace view rgsr.v_replay_determinism_check as
select
  r.run_id,
  r.seal_hash_sha256,
  r.replay_hash_sha256,
  case
    when r.seal_hash_sha256 is null or r.replay_hash_sha256 is null then null
    else (r.seal_hash_sha256 = r.replay_hash_sha256)
  end as hashes_match
from rgsr.engine_runs r;

comment on view rgsr.v_replay_determinism_check is
'Replay determinism invariant: for any run with both hashes present, seal_hash_sha256 must equal replay_hash_sha256.';

commit;