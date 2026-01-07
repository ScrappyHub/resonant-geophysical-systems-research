begin;

create schema if not exists rgsr;

-- ============================================================
-- Replay evidence (NON-BREAKING)
-- Stores: seal hash + replay hash + equality proof for a run/artifact.
-- Does not assume existing run/artifact table schemas.
-- ============================================================

create table if not exists rgsr.run_replay_evidence (
  evidence_id uuid primary key default gen_random_uuid(),
  run_id uuid null,          -- optional link (if you have engine_runs.id or similar)
  artifact_id uuid null,     -- optional link (if you have run_artifacts/artifacts)
  seal_hash_sha256 text null,
  replay_hash_sha256 text null,
  hashes_match boolean generated always as (
    case
      when seal_hash_sha256 is null or replay_hash_sha256 is null then null
      else seal_hash_sha256 = replay_hash_sha256
    end
  ) stored,
  canonicalization text not null default 'JCS',
  notes text null,
  created_at timestamptz not null default now()
);

-- Helpful indexes (safe even if run_id/artifact_id remain null)
create index if not exists ix_run_replay_evidence_run on rgsr.run_replay_evidence(run_id, created_at desc);
create index if not exists ix_run_replay_evidence_artifact on rgsr.run_replay_evidence(artifact_id, created_at desc);

-- Lock down: no public writes by default
revoke all on table rgsr.run_replay_evidence from public;
grant select on table rgsr.run_replay_evidence to authenticated, anon;
grant all on table rgsr.run_replay_evidence to service_role;

commit;