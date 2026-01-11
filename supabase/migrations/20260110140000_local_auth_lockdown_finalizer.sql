-- 20260110140000_local_auth_lockdown_finalizer.sql
-- LOCAL NO-BRICK FINALIZER (CANONICAL)
-- Policy: NEVER FAIL. Local hardening is enforced by tools/local/post_reset_lock_auth.ps1.

do $$
begin
  -- If auth schema doesn't exist, nothing to do.
  if not exists (select 1 from pg_namespace where nspname = 'auth') then
    raise notice 'LOCAL FINALIZER: auth schema missing; skipping.';
    return;
  end if;

  -- Best-effort only: migrations may not have privilege to revoke grants issued by supabase_admin.
  begin
    revoke usage on schema auth from public;
    revoke usage on schema auth from anon;
    revoke usage on schema auth from authenticated;
  exception when insufficient_privilege then
    null;
  when others then
    null;
  end;

  -- Post-condition: NOTICE only (no exception)
  begin
    if has_schema_privilege('anon','auth','USAGE')
       or has_schema_privilege('authenticated','auth','USAGE')
       or has_schema_privilege('public','auth','USAGE')
    then
      raise notice 'LOCAL FINALIZER: auth schema usage still granted (expected in some locals). Post-reset script will enforce.';
    else
      raise notice 'LOCAL FINALIZER: auth schema usage appears locked ✅';
    end if;
  exception when others then
    null;
  end;

end $$;
