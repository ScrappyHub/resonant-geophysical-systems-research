begin;

create schema if not exists rgsr;

-- ============================================================
-- 97500 CANONICAL REPAIR
-- Recreate:
--  - rgsr._resolve_admin_owner_uid()
--  - rgsr.admin_grant_entitlement(uuid,text,jsonb)
--  - rgsr.admin_grant_entitlement(text,jsonb)
-- FK-safe: never inserts fake UUIDs, never assumes auth.users has rows.
-- ============================================================

-- 0) Ensure rgsr.admin_uids exists (minimal contract: uid)
create table if not exists rgsr.admin_uids (
  uid uuid primary key,
  created_at timestamptz not null default now()
);

-- Optional notes column (only if missing)
do $$
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema='rgsr' and table_name='admin_uids' and column_name='notes'
  ) then
    alter table rgsr.admin_uids add column notes text null;
  end if;
end $$;

-- 1) Owner resolver: prefers admin_uids, else falls back to first auth.users row, else NULL
create or replace function rgsr._resolve_admin_owner_uid()
returns uuid
language sql
stable
set search_path = rgsr, public, core
as $$
  select coalesce(
    (select uid from rgsr.admin_uids where uid is not null order by created_at asc limit 1),
    (select id  from auth.users where id is not null order by created_at asc, id asc limit 1)
  );
$$;

revoke all on function rgsr._resolve_admin_owner_uid() from public;
grant execute on function rgsr._resolve_admin_owner_uid() to service_role;

-- 2) Owner-required admin grant RPC (3-arg)
create or replace function rgsr.admin_grant_entitlement(
  p_owner_uid uuid,
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
  if p_owner_uid is null then
    raise exception 'admin_grant_entitlement requires owner_uid (non-null).';
  end if;

  -- enter lane
  perform rgsr._set_admin_grant_lane(true);

  -- absolute bans remain absolute
  if rgsr.is_banned_entitlement_key(p_entitlement_key) then
    raise exception 'Instrument mode: entitlement key "%" is forbidden.', p_entitlement_key;
  end if;

  insert into rgsr.entitlements(entitlement_id, owner_uid, entitlement_key, entitlement_value)
  values (v_id, p_owner_uid, p_entitlement_key, coalesce(p_entitlement_value,'{}'::jsonb));

  -- exit lane
  perform rgsr._set_admin_grant_lane(false);
  return v_id;

exception when others then
  -- always exit lane
  perform rgsr._set_admin_grant_lane(false);
  raise;
end;
$$;

revoke all on function rgsr.admin_grant_entitlement(uuid, text, jsonb) from public;
grant execute on function rgsr.admin_grant_entitlement(uuid, text, jsonb) to service_role;

-- 3) Back-compat wrapper (2-arg) -> routes through resolver
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
  v_owner uuid;
begin
  v_owner := rgsr._resolve_admin_owner_uid();

  if v_owner is null then
    raise exception 'No owner uid available. Create an auth user and/or seed rgsr.admin_uids.';
  end if;

  return rgsr.admin_grant_entitlement(v_owner, p_entitlement_key, p_entitlement_value);
end;
$$;

revoke all on function rgsr.admin_grant_entitlement(text, jsonb) from public;
grant execute on function rgsr.admin_grant_entitlement(text, jsonb) to service_role;

commit;