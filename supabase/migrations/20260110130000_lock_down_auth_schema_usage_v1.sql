-- 20260110130000_lock_down_auth_schema_usage_v1.sql
-- Canonical: lock down auth schema visibility for non-privileged roles
-- CORE/RGSR POLICY: must never fail (best-effort hardening)

do $$
begin
  -- Only act if schema exists
  if not exists (select 1 from pg_namespace where nspname = 'auth') then
    raise notice 'AUTH LOCKDOWN: schema auth missing; skipping.';
    return;
  end if;

  -- Best-effort revoke schema usage
  begin
    revoke usage on schema auth from public;
    revoke usage on schema auth from anon;
    revoke usage on schema auth from authenticated;

    revoke all on schema auth from public;
    revoke all on schema auth from anon;
    revoke all on schema auth from authenticated;
  exception when insufficient_privilege then
    null;
  when others then
    null;
  end;

  -- Best-effort revoke object privileges
  begin
    revoke all privileges on all tables    in schema auth from public, anon, authenticated;
    revoke all privileges on all sequences in schema auth from public, anon, authenticated;
    revoke all privileges on all functions in schema auth from public, anon, authenticated;
  exception when insufficient_privilege then
    null;
  when others then
    null;
  end;

  -- Best-effort future-proof for common owner role
  begin
    if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
      begin
        execute 'alter default privileges for role supabase_auth_admin in schema auth revoke all on tables from public, anon, authenticated';
      exception when others then null; end;

      begin
        execute 'alter default privileges for role supabase_auth_admin in schema auth revoke all on sequences from public, anon, authenticated';
      exception when others then null; end;

      begin
        execute 'alter default privileges for role supabase_auth_admin in schema auth revoke all on functions from public, anon, authenticated';
      exception when others then null; end;
    end if;
  exception when others then
    null;
  end;

  -- NOTICE-only postcondition
  begin
    if has_schema_privilege('anon','auth','USAGE')
       or has_schema_privilege('authenticated','auth','USAGE')
       or has_schema_privilege('public','auth','USAGE')
    then
      raise notice 'AUTH LOCKDOWN: schema auth USAGE still granted to anon/authenticated/public (best-effort may be blocked here).';
    else
      raise notice 'AUTH LOCKDOWN: schema auth USAGE revoked for anon/authenticated/public ✅';
    end if;
  exception when others then
    null;
  end;

end $$;
