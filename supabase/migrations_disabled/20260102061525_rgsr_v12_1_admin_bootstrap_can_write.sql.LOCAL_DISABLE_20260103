-- ============================================================
-- RGSR v12.1 — ADMIN BOOTSTRAP (NO PII) / CORE GOVERNANCE
-- Purpose:
--   - Canonical admin allowlist by auth uid
--   - rgsr.can_write() becomes: actor_uid in allowlist
--   - Enables ADMIN_REQUIRED flows (billing ingest, moderation, deletion)
-- Notes:
--   - Stores NO emails/phones/names; only auth.users.id
--   - Does NOT alter auth.* schema
-- ============================================================

begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 1) Canonical admin allowlist
-- ------------------------------------------------------------
create table if not exists rgsr.admin_uids (
  uid uuid primary key references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

alter table rgsr.admin_uids enable row level security;
alter table rgsr.admin_uids force row level security;

-- Only admins can read/manage the admin list (self-referential gate).
do $do$
begin
  -- drop prior policies if any (avoid union leakage)
  perform 1;
  execute 'drop policy if exists admin_uids_read on rgsr.admin_uids';
  execute 'drop policy if exists admin_uids_admin on rgsr.admin_uids';
exception when others then
  -- ignore; idempotent
  null;
end
$do$;

-- rgsr.actor_uid() is assumed to already exist from v11.x/v11.3+
-- If it doesn't, STOP and fix actor_uid first.

-- ------------------------------------------------------------
-- 2) Canonical can_write() definition (CORE rule)
-- ------------------------------------------------------------
create or replace function rgsr.can_write()
returns boolean
language sql
stable
security invoker
as $fn$
  select exists (
    select 1
    from rgsr.admin_uids a
    where a.uid = rgsr.actor_uid()
  );
$fn$;

-- Policies for admin_uids
create policy admin_uids_read on rgsr.admin_uids
for select to authenticated
using (rgsr.can_write());

create policy admin_uids_admin on rgsr.admin_uids
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- ------------------------------------------------------------
-- 3) Seed known admin UIDs (your 5 auth.users ids)
-- ------------------------------------------------------------
insert into rgsr.admin_uids(uid) values
  ('d4ca5da1-b30a-44af-8b7e-2fd0fbc0bd2d'::uuid),
  ('ee11a221-cb04-4472-92f1-08534e1dd9e7'::uuid),
  ('ee9cd604-09ca-43c1-9738-5591efb65c2d'::uuid),
  ('57ea797c-a3ce-4c06-8da3-c6c7b9f5757c'::uuid),
  ('9186100f-f607-404e-8c18-24b457ca0ee4'::uuid)
on conflict (uid) do nothing;

commit;

-- ============================================================
-- Manual verification (SQL Editor):
--   select set_config('request.jwt.claim.sub','d4ca5da1-b30a-44af-8b7e-2fd0fbc0bd2d', true);
--   select set_config('request.jwt.claim.role','authenticated', true);
--   select rgsr.actor_uid() as actor, rgsr.can_write() as can_write;
-- ============================================================
