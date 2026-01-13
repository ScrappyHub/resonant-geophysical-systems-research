-- 20260113190000_instrument_engine_manifest_seed_and_resolver_v1.sql
-- CANONICAL: Instrument-grade engine release manifest plumbing
-- - Seeds engine_release_manifests for all engines in engine_registry.engines
-- - Provides resolver rgsr._resolve_engine_manifest_hash_for_run(run_id)
-- - Ensures binding uses engine_runs.config_id -> engine_configs.config_kind
-- - Restricts resolver to service_role only

begin;

-- 1) Seed manifests for every registered engine release.
-- NOTE: engine_registry.engines has (engine_code, version).
insert into engine_registry.engine_release_manifests (engine_code, engine_version, manifest)
select
  e.engine_code,
  e.version as engine_version,
  jsonb_build_object(
    'engine', jsonb_build_object(
      'code', e.engine_code,
      'version', e.version,
      'build', jsonb_build_object(
        'git_commit', coalesce(current_setting('app.build_git_commit', true), 'LOCAL'),
        'artifact_sha256', coalesce(current_setting('app.build_artifact_sha256', true), 'LOCAL')
      )
    ),
    'capabilities', jsonb_build_array(),
    'units', jsonb_build_object(
      'system', 'SI',
      'base', jsonb_build_array('m','kg','s','K','A','mol','cd')
    ),
    'determinism', jsonb_build_object(
      'seed_required', true,
      'random_sources', jsonb_build_array(),
      'fp_mode', 'strict'
    )
  ) as manifest
from engine_registry.engines e
on conflict (engine_code, engine_version) do update
set manifest = excluded.manifest;

-- 2) Canonical resolver: derive engine_code from run.config_id -> engine_configs.config_kind.
-- Then choose manifest by engine_code + engine_version.
-- Engine version selection order:
--   a) app.engine_version (session override), else
--   b) engine_registry.engines.version for that engine_code, else
--   c) '1.0.0'
create or replace function rgsr._resolve_engine_manifest_hash_for_run(p_run_id uuid)
returns text
language sql
stable
security definer
set search_path = public, rgsr, engine_registry
as $$
  with r as (
    select er.config_id
    from rgsr.engine_runs er
    where er.run_id = p_run_id
  ),
  c as (
    select ec.config_kind as engine_code
    from rgsr.engine_configs ec
    join r on r.config_id = ec.config_id
  ),
  v as (
    select
      c.engine_code,
      coalesce(
        nullif(current_setting('app.engine_version', true), ''),
        (select e.version from engine_registry.engines e where e.engine_code = c.engine_code limit 1),
        '1.0.0'
      ) as engine_version
    from c
  ),
  pick as (
    select m.manifest_hash_sha256
    from engine_registry.engine_release_manifests m
    join v on v.engine_code = m.engine_code and v.engine_version = m.engine_version
    order by m.created_at desc
    limit 1
  )
  select manifest_hash_sha256 from pick;
$$;

-- 3) Lock down resolver execution.
revoke all on function rgsr._resolve_engine_manifest_hash_for_run(uuid) from public;
revoke all on function rgsr._resolve_engine_manifest_hash_for_run(uuid) from anon;
revoke all on function rgsr._resolve_engine_manifest_hash_for_run(uuid) from authenticated;
grant execute on function rgsr._resolve_engine_manifest_hash_for_run(uuid) to service_role;

commit;
