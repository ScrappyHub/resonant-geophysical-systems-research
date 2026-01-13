-- 20260112121000_rgsr_physics_vectors_and_tolerances_v1.sql
-- CANONICAL: deterministic physics vectors + tolerances
-- Policy:
--   - Vectors are immutable inputs for reproducible experiments
--   - Tolerances are explicit and keyed by engine + version + metric

begin;

create schema if not exists rgsr;

-- canonical “input vector” store (what CI / A/B replays use)
create table if not exists rgsr.physics_vectors (
  vector_id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),

  -- namespace / identity
  engine_code text not null,
  engine_version text not null,
  vector_key text not null,           -- e.g. "demo_2d/smoke/001"
  label text null,

  -- deterministic input payload that drives config + initial state
  payload jsonb not null,

  -- optional expected output digest(s) for “golden” verification
  expected_output_hash_sha256 text null,
  expected_meta jsonb not null default '{}'::jsonb
);

create unique index if not exists ux_physics_vectors_identity
  on rgsr.physics_vectors(engine_code, engine_version, vector_key);

-- explicit numeric tolerances
create table if not exists rgsr.physics_tolerances (
  tol_id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),

  engine_code text not null,
  engine_version text not null,
  metric_key text not null,           -- e.g. "energy_total", "mass_conserved", "node_pressure_l2"
  abs_tol double precision null,
  rel_tol double precision null,

  notes text null
);

create unique index if not exists ux_physics_tolerances_identity
  on rgsr.physics_tolerances(engine_code, engine_version, metric_key);

commit;
