-- 20260106193000_instrument_mode_and_no_individual_researcher_v1.sql
-- Canonical: instrument-mode access gate + ban "individual researcher" entitlement paths
-- NOTE: Designed to be safe to run repeatedly.

begin;

-- -----------------------------------------------------------------------------
-- A) Canonical settings table (source of truth for "instrument mode")
-- -----------------------------------------------------------------------------
create schema if not exists core;

create table if not exists core.platform_settings (
  setting_key text primary key,
  setting_value jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid null
);

-- Seed instrument_mode=TRUE by default (locked down)
insert into core.platform_settings(setting_key, setting_value)
values ('instrument_mode', jsonb_build_object('enabled', true))
on conflict (setting_key) do nothing;

-- Helper: read instrument mode
create or replace function core.instrument_mode_enabled()
returns boolean
language sql
stable
as $$
  select coalesce((setting_value->>'enabled')::boolean, true)
  from core.platform_settings
  where setting_key='instrument_mode'
$$;

-- -----------------------------------------------------------------------------
-- B) Guardrail table: banned entitlement keys
-- -----------------------------------------------------------------------------
create schema if not exists rgsr;

create table if not exists rgsr.banned_entitlement_keys (
  entitlement_key text primary key,
  reason text not null,
  created_at timestamptz not null default now()
);

-- Ban the obvious strings (you can add more once discovery confirms exact keys)
insert into rgsr.banned_entitlement_keys(entitlement_key, reason)
values
  ('individual_researcher', 'Instrument mode: no self-serve individual researcher tier'),
  ('individual_researcher_tier', 'Instrument mode: no self-serve individual researcher tier'),
  ('researcher_individual', 'Instrument mode: no self-serve individual researcher tier')
on conflict (entitlement_key) do nothing;

-- -----------------------------------------------------------------------------
-- C) Enforce: entitlements cannot include banned keys (even if UI tries)
-- -----------------------------------------------------------------------------
create or replace function rgsr.enforce_banned_entitlement_keys()
returns trigger
language plpgsql
as $$
begin
  if exists (select 1 from rgsr.banned_entitlement_keys b where b.entitlement_key = new.entitlement_key) then
    raise exception 'Entitlement key "%" is banned: %',
      new.entitlement_key,
      (select reason from rgsr.banned_entitlement_keys b where b.entitlement_key=new.entitlement_key);
  end if;

  -- In instrument mode, also block *any* entitlement creation unless explicitly allowed later.
  -- This is the "no one can self-activate" posture.
  if core.instrument_mode_enabled() then
    -- allow updates to existing entitlements only (optional). We hard-block inserts.
    if (tg_op = 'INSERT') then
      raise exception 'Instrument mode: entitlement creation is locked. Use admin-controlled grants.';
    end if;
  end if;

  return new;
end;
$$;

-- Attach trigger to rgsr.entitlements
do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema='rgsr' and table_name='entitlements'
  ) then
    drop trigger if exists trg_enforce_banned_entitlement_keys on rgsr.entitlements;
    create trigger trg_enforce_banned_entitlement_keys
      before insert or update on rgsr.entitlements
      for each row execute function rgsr.enforce_banned_entitlement_keys();
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- D) Lock down invite/application surfaces while instrument_mode_enabled()
--    This prevents "open signups" for lab/institution access.
-- -----------------------------------------------------------------------------

-- Lab invites
do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema='rgsr' and table_name='lab_invites'
  ) then
    alter table rgsr.lab_invites enable row level security;

    drop policy if exists lab_invites_read on rgsr.lab_invites;
    drop policy if exists lab_invites_insert on rgsr.lab_invites;
    drop policy if exists lab_invites_update on rgsr.lab_invites;

    -- Read allowed for authenticated only if instrument mode is OFF (you can tighten later)
    create policy lab_invites_read
      on rgsr.lab_invites
      for select
      to authenticated
      using (not core.instrument_mode_enabled());

    -- Inserts/updates blocked in instrument mode for everyone except service_role
    -- (service_role bypasses RLS automatically; this policy denies authenticated)
    create policy lab_invites_insert
      on rgsr.lab_invites
      for insert
      to authenticated
      with check (not core.instrument_mode_enabled());

    create policy lab_invites_update
      on rgsr.lab_invites
      for update
      to authenticated
      using (not core.instrument_mode_enabled())
      with check (not core.instrument_mode_enabled());
  end if;
end $$;

-- Institution access applications
do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema='rgsr' and table_name='institution_access_applications'
  ) then
    alter table rgsr.institution_access_applications enable row level security;

    drop policy if exists institution_access_applications_read on rgsr.institution_access_applications;
    drop policy if exists institution_access_applications_insert on rgsr.institution_access_applications;
    drop policy if exists institution_access_applications_update on rgsr.institution_access_applications;

    create policy institution_access_applications_read
      on rgsr.institution_access_applications
      for select
      to authenticated
      using (not core.instrument_mode_enabled());

    create policy institution_access_applications_insert
      on rgsr.institution_access_applications
      for insert
      to authenticated
      with check (not core.instrument_mode_enabled());

    create policy institution_access_applications_update
      on rgsr.institution_access_applications
      for update
      to authenticated
      using (not core.instrument_mode_enabled())
      with check (not core.instrument_mode_enabled());
  end if;
end $$;

commit;
