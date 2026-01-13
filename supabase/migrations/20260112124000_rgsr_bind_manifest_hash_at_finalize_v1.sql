-- 20260112124000_rgsr_bind_manifest_hash_at_finalize_v1.sql
-- CANONICAL: bind engine release manifest hash onto engine_runs prior to seal
-- Instrument rule: a run cannot be sealed without an attached engine manifest hash.

begin;

create schema if not exists rgsr;

-- Helper: resolve manifest hash for a run.
-- Strategy:
--  1) Prefer engine_code = engine_kind, engine_version = COALESCE(app.engine_version,'1.0.0')
--  2) If multiple versions exist, take the latest created manifest for that engine_code.
create or replace function rgsr._resolve_engine_manifest_hash_for_run(p_run_id uuid)
returns text
language sql
stable
security definer
set search_path = public, rgsr, engine_registry
as $$
  with r as (
    select er.engine_kind as engine_code
    from rgsr.engine_runs er
    where er.run_id = p_run_id
  ),
  wanted as (
    select
      r.engine_code,
      nullif(current_setting('app.engine_version', true), '') as preferred_version
    from r
  ),
  pick as (
    select m.manifest_hash_sha256
    from engine_registry.engine_release_manifests m
    join wanted w on w.engine_code = m.engine_code
    where (w.preferred_version is null or m.engine_version = w.preferred_version)
    order by m.created_at desc
    limit 1
  )
  select manifest_hash_sha256 from pick;
$$;

revoke all on function rgsr._resolve_engine_manifest_hash_for_run(uuid) from public;
revoke all on function rgsr._resolve_engine_manifest_hash_for_run(uuid) from anon;
revoke all on function rgsr._resolve_engine_manifest_hash_for_run(uuid) from authenticated;
grant execute on function rgsr._resolve_engine_manifest_hash_for_run(uuid) to service_role;

-- Patch finalize_engine_run: set engine_manifest_hash_sha256 if missing, before sealing.
-- NOTE: this assumes you already have rgsr.finalize_engine_run(p_run_id uuid).
do $$
begin
  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'rgsr'
      and p.proname = 'finalize_engine_run'
      and pg_get_function_identity_arguments(p.oid) = 'p_run_id uuid'
  ) then
    -- Wrap by replacing with a shim that calls existing implementation is not possible
    -- in pure SQL without knowing its body. So we do the safest approach:
    -- enforce manifest hash via a BEFORE UPDATE trigger on status change to sealed.
    null;
  end if;
exception when others then
  null;
end $$;

-- Enforce at the exact moment status becomes 'sealed' (or seal_hash is set):
create or replace function rgsr._bind_manifest_hash_before_seal()
returns trigger
language plpgsql
security definer
set search_path = public, rgsr, engine_registry
as $$
declare
  v_hash text;
begin
  -- Only act when attempting to seal
  if (new.status = 'sealed') and (old.status is distinct from 'sealed') then
    if new.engine_manifest_hash_sha256 is null then
      v_hash := rgsr._resolve_engine_manifest_hash_for_run(new.run_id);

      if v_hash is null then
        raise exception using
          errcode = 'P0001',
          message = 'Instrument violation: no engine release manifest hash available for run',
          detail  = format('run_id=%s engine_kind=%s', new.run_id, new.engine_kind);
      end if;

      new.engine_manifest_hash_sha256 := v_hash;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists tg_bind_manifest_hash_before_seal on rgsr.engine_runs;
create trigger tg_bind_manifest_hash_before_seal
before update on rgsr.engine_runs
for each row
execute function rgsr._bind_manifest_hash_before_seal();

revoke all on function rgsr._bind_manifest_hash_before_seal() from public;
revoke all on function rgsr._bind_manifest_hash_before_seal() from anon;
revoke all on function rgsr._bind_manifest_hash_before_seal() from authenticated;
grant execute on function rgsr._bind_manifest_hash_before_seal() to service_role;

commit;
