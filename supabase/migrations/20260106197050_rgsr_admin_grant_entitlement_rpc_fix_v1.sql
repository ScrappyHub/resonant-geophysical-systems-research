begin;

create schema if not exists rgsr;

-- Admin lane setter (SECURITY DEFINER)
-- Note: 97100 will re-define this; defining here is safe + idempotent.
create or replace function rgsr._set_admin_grant_lane(p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = rgsr, public, core
as $$
begin
  perform set_config('rgsr.admin_grant_lane', case when p_enabled then 'on' else 'off' end, false);
end;
$$;

revoke all on function rgsr._set_admin_grant_lane(boolean) from public;
grant execute on function rgsr._set_admin_grant_lane(boolean) to service_role;

-- Canonical admin grant RPC
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
  -- enter lane
  perform rgsr._set_admin_grant_lane(true);

  -- absolute bans remain absolute
  if rgsr.is_banned_entitlement_key(p_entitlement_key) then
    raise exception 'Instrument mode: entitlement key "%" is forbidden.', p_entitlement_key;
  end if;

  insert into rgsr.entitlements(entitlement_id, entitlement_key, entitlement_value)
  values (v_id, p_entitlement_key, coalesce(p_entitlement_value,'{}'::jsonb));

  -- exit lane
  perform rgsr._set_admin_grant_lane(false);
  return v_id;

exception when others then
  -- always exit lane
  perform rgsr._set_admin_grant_lane(false);
  raise;
end;
$$;

revoke all on function rgsr.admin_grant_entitlement(text, jsonb) from public;
grant execute on function rgsr.admin_grant_entitlement(text, jsonb) to service_role;

commit;