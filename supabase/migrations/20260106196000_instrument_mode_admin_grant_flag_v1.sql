begin;

create schema if not exists rgsr;

-- SECURITY DEFINER can set a LOCAL flag to indicate "admin grant lane"
create or replace function rgsr._set_admin_grant_lane(p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = rgsr, public
as $$
begin
  perform set_config('rgsr.admin_grant_lane', case when p_enabled then 'on' else 'off' end, true);
end;
$$;

revoke all on function rgsr._set_admin_grant_lane(boolean) from public;
revoke all on function rgsr._set_admin_grant_lane(boolean) from anon;
revoke all on function rgsr._set_admin_grant_lane(boolean) from authenticated;

do $$
begin
  begin
    grant execute on function rgsr._set_admin_grant_lane(boolean) to service_role;
  exception when undefined_object then
    null;
  end;
  grant execute on function rgsr._set_admin_grant_lane(boolean) to postgres;
end;
$$;

-- Patch enforcement function: allow admin_grant_lane OR sys_admin
create or replace function rgsr.enforce_banned_entitlement_keys()
returns trigger
language plpgsql
as $$
declare
  v_instrument boolean;
  v_key text;
  v_admin_lane boolean;
begin
  v_instrument := core.instrument_mode_enabled();
  v_key := lower(coalesce(new.entitlement_key, ''));

  v_admin_lane := coalesce(nullif(current_setting('rgsr.admin_grant_lane', true), ''), 'off') = 'on';

  -- Absolute bans
  if exists (
    select 1 from rgsr.banned_entitlement_keys bek
    where lower(bek.entitlement_key) = v_key
  ) then
    raise exception 'Instrument mode: entitlement key "%" is forbidden.', new.entitlement_key;
  end if;

  -- Instrument mode gate: only sys_admin OR admin_grant_lane may write
  if v_instrument and (not v_admin_lane) and (not rgsr.is_sys_admin()) then
    raise exception 'Instrument mode: entitlement writes are locked. Admin-controlled grants only.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_enforce_banned_entitlement_keys on rgsr.entitlements;
create trigger trg_enforce_banned_entitlement_keys
before insert or update on rgsr.entitlements
for each row
execute function rgsr.enforce_banned_entitlement_keys();

commit;
