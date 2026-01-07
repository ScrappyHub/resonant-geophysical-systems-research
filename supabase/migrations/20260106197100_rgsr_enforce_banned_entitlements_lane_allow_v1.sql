begin;

create schema if not exists rgsr;

-- Canonical lane checker
create or replace function rgsr._is_admin_grant_lane()
returns boolean
language sql
stable
set search_path = rgsr, public, core
as $$
  select coalesce(nullif(current_setting('rgsr.admin_grant_lane', true), ''), 'off') = 'on';
$$;

revoke all on function rgsr._is_admin_grant_lane() from public;
grant execute on function rgsr._is_admin_grant_lane() to service_role;

-- Canonical lane setter (session-level; third arg = false)
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

-- Trigger function: bans are absolute; instrument lock allows sys_admin OR admin_grant_lane
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
  v_admin_lane := rgsr._is_admin_grant_lane();

  -- Absolute bans ALWAYS
  if exists (
    select 1 from rgsr.banned_entitlement_keys bek
    where lower(bek.entitlement_key) = v_key
  ) then
    raise exception 'Instrument mode: entitlement key "%" is forbidden.', new.entitlement_key;
  end if;

  -- Instrument mode: only sys_admin OR admin_grant_lane may write
  if v_instrument and (not v_admin_lane) and (not rgsr.is_sys_admin()) then
    raise exception 'Instrument mode: entitlement writes are locked. Admin-controlled grants only.';
  end if;

  return new;
end;
$$;

commit;