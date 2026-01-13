-- 20260112122500_core_can_run_restrict_exec_by_oid_v1.sql
-- CANONICAL: restrict execute privileges for core.can_run (SECURITY DEFINER)
-- Instrument posture: SECURITY DEFINER "gates" must not be callable by end-user roles.
-- Implementation: revoke/grant by OID to avoid signature/overload mismatch footguns.

begin;

do $$
declare
  r record;
begin
  for r in
    select
      p.oid,
      n.nspname as schema,
      p.proname as name,
      pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'core'
      and p.proname = 'can_run'
  loop
    -- hard revoke
    execute format('revoke all on function %s from public', r.oid::regprocedure);
    execute format('revoke all on function %s from anon', r.oid::regprocedure);
    execute format('revoke all on function %s from authenticated', r.oid::regprocedure);

    -- service_role only
    execute format('grant execute on function %s to service_role', r.oid::regprocedure);

    -- optional supabase_admin
    if exists (select 1 from pg_roles where rolname = 'supabase_admin') then
      execute format('grant execute on function %s to supabase_admin', r.oid::regprocedure);
    end if;
  end loop;
end $$;

commit;
