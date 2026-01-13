-- 20260112122000_core_can_run_restrict_exec_v1.sql
-- CANONICAL: restrict core.can_run execute privileges (SECURITY DEFINER)
-- Instrument posture: SECURITY DEFINER functions must not be callable by end-user roles.

begin;

revoke all on function core.can_run(uuid, uuid, text, text, text, jsonb) from public;
revoke all on function core.can_run(uuid, uuid, text, text, text, jsonb) from anon;
revoke all on function core.can_run(uuid, uuid, text, text, text, jsonb) from authenticated;

grant execute on function core.can_run(uuid, uuid, text, text, text, jsonb) to service_role;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_admin') then
    grant execute on function core.can_run(uuid, uuid, text, text, text, jsonb) to supabase_admin;
  end if;
exception when others then
  null;
end $$;

commit;
