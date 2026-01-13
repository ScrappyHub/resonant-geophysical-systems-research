-- 20260112123000_engine_release_capability_manifests_v1.sql
-- CANONICAL: Engine release capability manifests (signed-by-hash instrument posture)
-- Store JSONB manifest, compute deterministic sha256 hash, bind runs to manifest at seal-time.

begin;

create schema if not exists engine_registry;

-- ------------------------------------------------------------
-- Helpers: stable jsonb canonicalization + sha256
-- ------------------------------------------------------------

-- Canonical JSON stringify (stable ordering). Postgres::jsonb::text is deterministic for key order.
-- We still wrap it as a function for explicitness and future-proofing.
create or replace function engine_registry._canonical_json_text(p jsonb)
returns text
language sql
immutable
as $$
  select coalesce(p, '{}'::jsonb)::text
$$;

create or replace function engine_registry._sha256_hex(p_text text)
returns text
language sql
immutable
as $$
  select encode(digest(coalesce(p_text,''), 'sha256'), 'hex')
$$;

create or replace function engine_registry.manifest_hash_sha256(p_manifest jsonb)
returns text
language sql
immutable
as $$
  select engine_registry._sha256_hex(engine_registry._canonical_json_text(p_manifest))
$$;

-- ------------------------------------------------------------
-- Table: per-engine-release manifest
-- ------------------------------------------------------------

create table if not exists engine_registry.engine_release_manifests (
  manifest_id uuid primary key default gen_random_uuid(),

  engine_code text not null,
  engine_version text not null,

  -- authoritative manifest
  manifest jsonb not null,

  -- computed hash of canonical json form
  manifest_hash_sha256 text not null,

  created_at timestamptz not null default now(),
  created_by uuid null,

  -- one manifest per engine release
  constraint engine_release_manifest_ux unique (engine_code, engine_version),
  constraint engine_release_manifest_hash_ux unique (manifest_hash_sha256),
  constraint manifest_hash_format_chk check (manifest_hash_sha256 ~ '^[0-9a-f]{64}$')
);

-- Keep hash in sync on insert/update (but we generally treat manifest as append-only)
create or replace function engine_registry.trg_set_manifest_hash()
returns trigger
language plpgsql
as $$
begin
  new.manifest_hash_sha256 := engine_registry.manifest_hash_sha256(new.manifest);
  return new;
end;
$$;

drop trigger if exists trg_set_manifest_hash on engine_registry.engine_release_manifests;
create trigger trg_set_manifest_hash
before insert or update of manifest
on engine_registry.engine_release_manifests
for each row execute function engine_registry.trg_set_manifest_hash();

-- ------------------------------------------------------------
-- Bind engine runs to a manifest hash at seal time
-- ------------------------------------------------------------

alter table if exists rgsr.engine_runs
  add column if not exists engine_manifest_hash_sha256 text;

-- format check if present
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'engine_runs_manifest_hash_format_chk'
  ) then
    alter table rgsr.engine_runs
      add constraint engine_runs_manifest_hash_format_chk
      check (engine_manifest_hash_sha256 is null or engine_manifest_hash_sha256 ~ '^[0-9a-f]{64}$');
  end if;
end $$;

-- Resolve manifest hash for a given engine_code + engine_version
create or replace function engine_registry.get_manifest_hash(p_engine_code text, p_engine_version text)
returns text
language sql
stable
security definer
set search_path = public, engine_registry
as $$
  select erm.manifest_hash_sha256
  from engine_registry.engine_release_manifests erm
  where erm.engine_code = p_engine_code
    and erm.engine_version = p_engine_version
$$;

revoke all on function engine_registry.get_manifest_hash(text,text) from public;
revoke all on function engine_registry.get_manifest_hash(text,text) from anon;
revoke all on function engine_registry.get_manifest_hash(text,text) from authenticated;
grant execute on function engine_registry.get_manifest_hash(text,text) to service_role;

do $$
begin
  if exists (select 1 from pg_roles where rolname='supabase_admin') then
    grant execute on function engine_registry.get_manifest_hash(text,text) to supabase_admin;
  end if;
exception when others then null;
end $$;

-- ------------------------------------------------------------
-- Seal-time enforcement:
-- when sealing, engine_runs.engine_manifest_hash_sha256 must be set and then immutable
-- We assume you already have finalize/seal RPCs; we enforce with a trigger that:
--   - blocks changing engine_manifest_hash_sha256 after status='sealed'
--   - blocks sealing if engine_manifest_hash_sha256 is null
-- ------------------------------------------------------------

create or replace function rgsr._guard_manifest_hash_after_seal()
returns trigger
language plpgsql
security definer
set search_path = public, rgsr
as $$
begin
  -- once sealed: no mutation
  if old.status = 'sealed' then
    if new.engine_manifest_hash_sha256 is distinct from old.engine_manifest_hash_sha256 then
      raise exception 'instrument_violation: cannot modify engine_manifest_hash_sha256 after seal';
    end if;
  end if;

  -- on transition to sealed: must have hash
  if old.status is distinct from 'sealed' and new.status = 'sealed' then
    if new.engine_manifest_hash_sha256 is null then
      raise exception 'instrument_violation: cannot seal run without engine_manifest_hash_sha256';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists tg_guard_engine_manifest_hash_after_seal on rgsr.engine_runs;
create trigger tg_guard_engine_manifest_hash_after_seal
before update on rgsr.engine_runs
for each row
execute function rgsr._guard_manifest_hash_after_seal();

revoke all on function rgsr._guard_manifest_hash_after_seal() from public;
revoke all on function rgsr._guard_manifest_hash_after_seal() from anon;
revoke all on function rgsr._guard_manifest_hash_after_seal() from authenticated;

-- ------------------------------------------------------------
-- Permissions on manifest table (instrument posture)
-- Only service_role/supabase_admin should be able to mutate manifests.
-- Reading manifests can be allowed later via vetted views; default deny.
-- ------------------------------------------------------------

alter table engine_registry.engine_release_manifests enable row level security;

-- deny by default (no policies) – service_role bypasses RLS normally.
revoke all on table engine_registry.engine_release_manifests from public;
revoke all on table engine_registry.engine_release_manifests from anon;
revoke all on table engine_registry.engine_release_manifests from authenticated;

grant select, insert, update, delete on table engine_registry.engine_release_manifests to service_role;

do $$
begin
  if exists (select 1 from pg_roles where rolname='supabase_admin') then
    grant select, insert, update, delete on table engine_registry.engine_release_manifests to supabase_admin;
  end if;
exception when others then null;
end $$;

commit;
