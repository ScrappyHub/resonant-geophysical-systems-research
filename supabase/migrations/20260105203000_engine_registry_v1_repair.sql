begin;

create extension if not exists pgcrypto;
create schema if not exists engine_registry;

-- enums (idempotent via DO)
do $$
begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='engine_registry' and t.typname='artifact_kind'
  ) then
    create type engine_registry.artifact_kind as enum ('ENGINE_DEF','POLICY_DEF','RUN_INPUT','RUN_OUTPUT','RUN_META');
  end if;

  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='engine_registry' and t.typname='lane_class'
  ) then
    create type engine_registry.lane_class as enum ('PUBLIC','RESTRICTED','SENSITIVE','CLASSIFIED');
  end if;

  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='engine_registry' and t.typname='domain_class'
  ) then
    create type engine_registry.domain_class as enum ('KINEMATICS','METEOROLOGY','HYDROLOGY','GEOSCIENCE','SIGNAL','TIME','UNITS','OTHER');
  end if;
end
$$;

-- engines (in case partial)
create table if not exists engine_registry.engines (
  engine_id            uuid primary key default gen_random_uuid(),
  engine_code          text not null,
  engine_name          text not null,
  domain               engine_registry.domain_class not null default 'OTHER',
  version              text not null,
  deterministic        boolean not null default true,
  headless             boolean not null default true,
  network_access       boolean not null default false,
  user_aware           boolean not null default false,
  governance_aware     boolean not null default false,
  allowed_inputs_json  jsonb not null default '{}'::jsonb,
  output_schema_json   jsonb not null default '{}'::jsonb,
  canonical_units_json jsonb not null default '{}'::jsonb,
  coupling_rules_json  jsonb not null default '{}'::jsonb,
  lane                engine_registry.lane_class not null default 'RESTRICTED',
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid null,
  notes               text null
);

create unique index if not exists engines_code_version_ux
  on engine_registry.engines(engine_code, version);

-- policies
create table if not exists engine_registry.policies (
  policy_id            uuid primary key default gen_random_uuid(),
  policy_code          text not null,
  policy_name          text not null,
  version              text not null,
  applies_to_engine    text null,
  thresholds_json      jsonb not null default '{}'::jsonb,
  output_schema_json   jsonb not null default '{}'::jsonb,
  lane                engine_registry.lane_class not null default 'RESTRICTED',
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid null,
  notes               text null
);

create unique index if not exists policies_code_version_ux
  on engine_registry.policies(policy_code, version);

-- verticals
create table if not exists engine_registry.verticals (
  vertical_id          uuid primary key default gen_random_uuid(),
  vertical_code        text not null,
  vertical_name        text not null,
  lane                engine_registry.lane_class not null default 'RESTRICTED',
  composition_json     jsonb not null default '{}'::jsonb,
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  created_by          uuid null,
  notes               text null
);

create unique index if not exists verticals_code_ux
  on engine_registry.verticals(vertical_code);

-- vertical engines
create table if not exists engine_registry.vertical_engines (
  vertical_engine_id   uuid primary key default gen_random_uuid(),
  vertical_code        text not null,
  engine_code          text not null,
  engine_version       text not null,
  enabled              boolean not null default true,
  constraints_json     jsonb not null default '{}'::jsonb,
  created_at           timestamptz not null default now()
);

create unique index if not exists vertical_engines_ux
  on engine_registry.vertical_engines(vertical_code, engine_code, engine_version);

-- vertical policies
create table if not exists engine_registry.vertical_policies (
  vertical_policy_id   uuid primary key default gen_random_uuid(),
  vertical_code        text not null,
  policy_code          text not null,
  policy_version       text not null,
  enabled              boolean not null default true,
  constraints_json     jsonb not null default '{}'::jsonb,
  created_at           timestamptz not null default now()
);

create unique index if not exists vertical_policies_ux
  on engine_registry.vertical_policies(vertical_code, policy_code, policy_version);

-- artifacts + hash helper
create table if not exists engine_registry.artifacts (
  artifact_id          uuid primary key default gen_random_uuid(),
  artifact_kind        engine_registry.artifact_kind not null,
  subject_code         text not null,
  subject_version      text null,
  content_type         text not null default 'application/json',
  content_json         jsonb not null default '{}'::jsonb,
  sha256_hex           text not null,
  created_at           timestamptz not null default now(),
  created_by           uuid null,
  notes                text null
);

create unique index if not exists artifacts_kind_subject_ux
  on engine_registry.artifacts(artifact_kind, subject_code, coalesce(subject_version,''));

create or replace function engine_registry.sha256_jsonb_hex(p jsonb)
returns text
language sql
immutable
as $$
  select encode(digest(convert_to(p::text,'utf8'),'sha256'),'hex');
$$;

commit;