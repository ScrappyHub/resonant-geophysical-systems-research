begin;

-- Ensure schemas exist
create schema if not exists core;
create schema if not exists rgsr;

-- Replace enforcement: in instrument mode, only sys_admin can write entitlements.
-- Also enforce banned keys always (even for sys_admin), unless you explicitly want sys_admin override.
create or replace function rgsr.enforce_banned_entitlement_keys()
returns trigger
language plpgsql
as $$
declare
  v_instrument boolean;
  v_key text;
begin
  v_instrument := core.instrument_mode_enabled();

  -- Normalize key for matching
  v_key := lower(coalesce(new.entitlement_key, ''));

  -- Absolute bans (never allow)
  if exists (
    select 1
    from rgsr.banned_entitlement_keys bek
    where lower(bek.entitlement_key) = v_key
  ) then
    raise exception 'Instrument mode: entitlement key "%" is forbidden.', new.entitlement_key;
  end if;

  -- Instrument mode gate: only sys_admin can insert/update/delete entitlements
  if v_instrument and not rgsr.is_sys_admin() then
    raise exception 'Instrument mode: entitlement writes are locked. Admin-controlled grants only.';
  end if;

  return new;
end;
$$;

-- Ensure trigger exists and points to the updated function
drop trigger if exists trg_enforce_banned_entitlement_keys on rgsr.entitlements;
create trigger trg_enforce_banned_entitlement_keys
before insert or update on rgsr.entitlements
for each row
execute function rgsr.enforce_banned_entitlement_keys();

commit;
