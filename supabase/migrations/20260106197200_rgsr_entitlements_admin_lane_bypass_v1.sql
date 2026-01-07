begin;

-- Ensure the lane helpers exist (safe to re-create)
create or replace function rgsr._set_admin_grant_lane(p_enabled boolean)
returns void
language plpgsql
security definer
set search_path = rgsr, public, core
as $$
begin
  perform set_config('rgsr.admin_grant_lane', case when p_enabled then 'on' else 'off' end, true);
end;
$$;

create or replace function rgsr._is_admin_grant_lane()
returns boolean
language sql
stable
set search_path = rgsr, public, core
as $$
  select coalesce(current_setting('rgsr.admin_grant_lane', true), 'off') = 'on';
$$;

-- Patch trigger function: allow admin lane to write non-banned keys
create or replace function rgsr.enforce_banned_entitlement_keys()
returns trigger
language plpgsql
security definer
set search_path = rgsr, public, core
as $$
begin
  -- Always block banned keys (even in admin lane)
  if rgsr.is_banned_entitlement_key(new.entitlement_key) then
    raise exception 'Instrument mode: entitlement key "%" is forbidden.', new.entitlement_key;
  end if;

  -- In instrument mode, block direct writes unless admin lane is active
  if core.instrument_mode_enabled() and not rgsr._is_admin_grant_lane() then
    raise exception 'Instrument mode: entitlement writes are locked. Admin-controlled grants only.';
  end if;

  return new;
end;
$$;

-- Ensure trigger points to updated function (idempotent)
drop trigger if exists trg_enforce_banned_entitlement_keys on rgsr.entitlements;
create trigger trg_enforce_banned_entitlement_keys
before insert or update on rgsr.entitlements
for each row
execute function rgsr.enforce_banned_entitlement_keys();

commit;
