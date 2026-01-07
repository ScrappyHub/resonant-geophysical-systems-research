begin;

alter table rgsr.engine_runs
  add column if not exists seal_hash_sha256 text null;

alter table rgsr.engine_runs
  add column if not exists replay_hash_sha256 text null;

alter table rgsr.engine_runs
  add column if not exists hashes_match boolean
  generated always as (
    case
      when seal_hash_sha256 is null or replay_hash_sha256 is null then null
      else seal_hash_sha256 = replay_hash_sha256
    end
  ) stored;

create index if not exists ix_engine_runs_hashes
  on rgsr.engine_runs (seal_hash_sha256, replay_hash_sha256);

commit;
