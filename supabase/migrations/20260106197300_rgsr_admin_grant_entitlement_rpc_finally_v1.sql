begin;

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
  perform rgsr._set_admin_grant_lane(true);

  if rgsr.is_banned_entitlement_key(p_entitlement_key) then
    raise exception 'Instrument mode: entitlement key "%" is forbidden.', p_entitlement_key;
  end if;

  insert into rgsr.entitlements(entitlement_id, entitlement_key, entitlement_value)
  values (v_id, p_entitlement_key, coalesce(p_entitlement_value,'{}'::jsonb));

  perform rgsr._set_admin_grant_lane(false);
  return v_id;

exception when others then
  perform rgsr._set_admin_grant_lane(false);
  raise;
end;
$$;

revoke all on function rgsr.admin_grant_entitlement(text, jsonb) from public;
grant execute on function rgsr.admin_grant_entitlement(text, jsonb) to service_role;

commit;
