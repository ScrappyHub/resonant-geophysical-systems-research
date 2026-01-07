begin;

create schema if not exists rgsr;

-- Helper: hard check for banned keys (case-insensitive)
create or replace function rgsr.is_banned_entitlement_key(p_key text)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from rgsr.banned_entitlement_keys bek
    where lower(bek.entitlement_key) = lower(coalesce(p_key,''))
  );
$$;

-- Admin-controlled grant path. This is the ONLY intended write lane in instrument mode.
-- NOTE: This bypasses rgsr.is_sys_admin() gating because it is explicitly admin-operated.
create or replace function rgsr.admin_grant_entitlement(
  p_entitlement_key text,
  p_entitlement_value jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = rgsr, public, core
as $$
declare
  v_id uuid := gen_random_uuid();
begin
  if rgsr.is_banned_entitlement_key(p_entitlement_key) then
    raise exception 'Instrument mode: entitlement key "%" is forbidden.', p_entitlement_key;
  end if;

  insert into rgsr.entitlements(entitlement_id, entitlement_key, entitlement_value)
  values (v_id, p_entitlement_key, coalesce(p_entitlement_value,'{}'::jsonb));

  return v_id;
end;
$$;

-- Lock down who can execute it.
-- In Supabase, you typically want only service_role / postgres / privileged roles.
revoke all on function rgsr.admin_grant_entitlement(text, jsonb) from public;
revoke all on function rgsr.admin_grant_entitlement(text, jsonb) from anon;
revoke all on function rgsr.admin_grant_entitlement(text, jsonb) from authenticated;

-- Allow postgres (local) and service_role (Supabase) to run it.
-- service_role exists in Supabase managed projects; in local it may also exist.
do $$
begin
  begin
    grant execute on function rgsr.admin_grant_entitlement(text, jsonb) to service_role;
  exception when undefined_object then
    -- service_role may not exist in some local contexts; ignore safely
    null;
  end;

  grant execute on function rgsr.admin_grant_entitlement(text, jsonb) to postgres;
end;
$$;

commit;
