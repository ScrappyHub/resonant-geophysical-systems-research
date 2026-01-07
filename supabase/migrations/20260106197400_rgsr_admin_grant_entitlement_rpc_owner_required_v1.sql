begin;

create schema if not exists rgsr;

-- ============================================================
-- 97400 CANONICAL (FK-safe)
-- Owner-required admin grant RPC + owner resolver
-- NEVER inserts fake UUIDs (admin_uids.uid has FK -> auth.users.id)
-- ============================================================

-- 1) Ensure rgsr.admin_uids exists (minimal contract: uid)
create table if not exists rgsr.admin_uids (
  uid uuid primary key,
  created_at timestamptz not null default now()
);

-- 2) Optional metadata column (only if missing)
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

-- 3) Seed admin_uids ONLY if:
--    - admin_uids is empty
--    - and auth.users has at least one row
--    Deterministic pick: oldest created_at then id.
do $$
declare
  v_uid uuid;
  v_has_notes boolean;
begin
  if not exists (select 1 from rgsr.admin_uids) then
    select u.id
    into v_uid
    from auth.users u
    order by u.created_at asc, u.id asc
    limit 1;

    if v_uid is not null then
      v_has_notes := exists (
        select 1
        from information_schema.columns
        where table_schema='rgsr' and table_name='admin_uids' and column_name='notes'
      );

      if v_has_notes then
        insert into rgsr.admin_uids(uid, notes)
        values (v_uid, 'CANONICAL DEV SEED: first auth.users.id at reset-time');
      else
        insert into rgsr.admin_uids(uid)
        values (v_uid);
      end if;
    else
      raise notice '97400: auth.users is empty during reset; skipping admin_uids seed (FK-safe).';
    end if;
  end if;
end $$;

-- 4) Canonical owner resolver:
--    prefers admin_uids, else falls back to first auth.users, else NULL.
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

-- 5) Canonical owner-required admin grant RPC (3-arg)
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

  perform rgsr._set_admin_grant_lane(true);

  if rgsr.is_banned_entitlement_key(p_entitlement_key) then
    raise exception 'Instrument mode: entitlement key "%" is forbidden.', p_entitlement_key;
  end if;

  insert into rgsr.entitlements(entitlement_id, owner_uid, entitlement_key, entitlement_value)
  values (v_id, p_owner_uid, p_entitlement_key, coalesce(p_entitlement_value,'{}'::jsonb));

  perform rgsr._set_admin_grant_lane(false);
  return v_id;

exception when others then
  perform rgsr._set_admin_grant_lane(false);
  raise;
end;
$$;

revoke all on function rgsr.admin_grant_entitlement(uuid, text, jsonb) from public;
grant execute on function rgsr.admin_grant_entitlement(uuid, text, jsonb) to service_role;

-- 6) Back-compat wrapper (2-arg) -> routes through resolver
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
    raise exception 'No owner uid available (auth.users empty). Create a user, then seed rgsr.admin_uids.';
  end if;

  return rgsr.admin_grant_entitlement(v_owner, p_entitlement_key, p_entitlement_value);
end;
$$;

revoke all on function rgsr.admin_grant_entitlement(text, jsonb) from public;
grant execute on function rgsr.admin_grant_entitlement(text, jsonb) to service_role;

commit;