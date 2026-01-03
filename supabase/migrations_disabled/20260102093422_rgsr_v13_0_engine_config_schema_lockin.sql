-- ============================================================
-- RGSR v13.0 — ENGINE CONFIG SCHEMA (PROVABLE)
-- - One canonical JSON shape for demo/workbench configs
-- - Deterministic seed + versioning
-- - Server-side validation (no UI-only truth)
-- - RLS: owner read/write; public read only for DEMO configs if desired later
-- ============================================================

begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 1) engine_configs (validated JSON)
-- ------------------------------------------------------------
create table if not exists rgsr.engine_configs (
  config_id uuid primary key default gen_random_uuid(),
  owner_uid uuid not null references auth.users(id) on delete restrict,

  -- 'demo' = website demonstrator (fixed scope)
  -- 'workbench' = instrument (paid gating)
  config_kind text not null default 'workbench',

  -- semantic version / schema version
  schema_version int not null default 1,

  -- Determinism
  seed bigint not null default 1,

  -- Config payload (validated)
  config jsonb not null default '{}'::jsonb,

  -- Metadata (no PII)
  title text not null default '',
  description text not null default '',
  tags text[] not null default '{}'::text[],
  metadata jsonb not null default '{}'::jsonb,

  -- lifecycle
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint engine_configs_kind_chk check (config_kind in ('demo','workbench')),
  constraint engine_configs_schema_version_chk check (schema_version >= 1),
  constraint engine_configs_seed_chk check (seed >= 0),
  constraint engine_configs_title_len_chk check (length(title) <= 120),
  constraint engine_configs_desc_len_chk check (length(description) <= 2000)
);

create index if not exists ix_engine_configs_owner_time on rgsr.engine_configs(owner_uid, created_at desc);
create index if not exists ix_engine_configs_kind on rgsr.engine_configs(config_kind);
create index if not exists gin_engine_configs_config on rgsr.engine_configs using gin (config);

-- ------------------------------------------------------------
-- 2) Canonical validator (schema v1)
-- Returns: { ok: bool, errors: [ {path,msg}... ] }
-- ------------------------------------------------------------
create or replace function rgsr.validate_engine_config_v1(p_config jsonb)
returns jsonb
language plpgsql
immutable
as $fn$
declare
  errs jsonb := '[]'::jsonb;

  -- helpers
  function add_err(p_path text, p_msg text) returns void
  language plpgsql
  as $f$
  begin
    errs := errs || jsonb_build_array(jsonb_build_object('path', p_path, 'msg', p_msg));
  end
  $f$;

  v_domains jsonb;
  v_geom jsonb;
  v_exc jsonb;
  v_mat jsonb;
  v_water jsonb;
  v_therm jsonb;
  v_atm jsonb;
  v_em jsonb;
  v_nodes jsonb;

  v_num numeric;
  v_txt text;
begin
  if p_config is null or jsonb_typeof(p_config) <> 'object' then
    add_err('$', 'config must be a JSON object');
    return jsonb_build_object('ok', false, 'errors', errs);
  end if;

  -- Required top-level keys
  if not (p_config ? 'domains') then add_err('$.domains','missing'); end if;
  if not (p_config ? 'geometry') then add_err('$.geometry','missing'); end if;
  if not (p_config ? 'excitation') then add_err('$.excitation','missing'); end if;
  if not (p_config ? 'materials') then add_err('$.materials','missing'); end if;
  if not (p_config ? 'water') then add_err('$.water','missing'); end if;
  if not (p_config ? 'thermal') then add_err('$.thermal','missing'); end if;
  if not (p_config ? 'atmosphere') then add_err('$.atmosphere','missing'); end if;
  if not (p_config ? 'electromagnetic') then add_err('$.electromagnetic','missing'); end if;
  if not (p_config ? 'nodes') then add_err('$.nodes','missing'); end if;

  if jsonb_array_length(errs) > 0 then
    return jsonb_build_object('ok', false, 'errors', errs);
  end if;

  v_domains := p_config->'domains';
  v_geom    := p_config->'geometry';
  v_exc     := p_config->'excitation';
  v_mat     := p_config->'materials';
  v_water   := p_config->'water';
  v_therm   := p_config->'thermal';
  v_atm     := p_config->'atmosphere';
  v_em      := p_config->'electromagnetic';
  v_nodes   := p_config->'nodes';

  -- domains: object of booleans
  if jsonb_typeof(v_domains) <> 'object' then add_err('$.domains','must be object'); end if;

  -- geometry
  if jsonb_typeof(v_geom) <> 'object' then add_err('$.geometry','must be object'); end if;
  if not (v_geom ? 'kind') then add_err('$.geometry.kind','missing'); end if;

  -- excitation parameters
  if jsonb_typeof(v_exc) <> 'object' then add_err('$.excitation','must be object'); end if;

  -- materials
  if jsonb_typeof(v_mat) <> 'object' then add_err('$.materials','must be object'); end if;

  -- water/thermal/atm/em must be objects
  if jsonb_typeof(v_water) <> 'object' then add_err('$.water','must be object'); end if;
  if jsonb_typeof(v_therm) <> 'object' then add_err('$.thermal','must be object'); end if;
  if jsonb_typeof(v_atm) <> 'object' then add_err('$.atmosphere','must be object'); end if;
  if jsonb_typeof(v_em) <> 'object' then add_err('$.electromagnetic','must be object'); end if;

  -- nodes must be array
  if jsonb_typeof(v_nodes) <> 'array' then add_err('$.nodes','must be array'); end if;

  -- Validate common excitation ranges (matching your UI)
  -- frequency_hz: 0..50000
  if (v_exc ? 'frequency_hz') then
    begin
      v_num := (v_exc->>'frequency_hz')::numeric;
      if v_num < 0 or v_num > 50000 then add_err('$.excitation.frequency_hz','out of range 0..50000'); end if;
    exception when others then add_err('$.excitation.frequency_hz','must be number'); end;
  else
    add_err('$.excitation.frequency_hz','missing');
  end if;

  -- amplitude: 0..1
  if (v_exc ? 'amplitude') then
    begin
      v_num := (v_exc->>'amplitude')::numeric;
      if v_num < 0 or v_num > 1 then add_err('$.excitation.amplitude','out of range 0..1'); end if;
    exception when others then add_err('$.excitation.amplitude','must be number'); end;
  else
    add_err('$.excitation.amplitude','missing');
  end if;

  -- waveform enum
  if (v_exc ? 'waveform') then
    v_txt := lower(nullif(v_exc->>'waveform',''));
    if v_txt not in ('sine','square','triangle','noise','pulse') then
      add_err('$.excitation.waveform',"invalid (sine|square|triangle|noise|pulse)");
    end if;
  else
    add_err('$.excitation.waveform','missing');
  end if;

  -- phase_offset_deg: -360..360 (or 0..360 if you prefer)
  if (v_exc ? 'phase_offset_deg') then
    begin
      v_num := (v_exc->>'phase_offset_deg')::numeric;
      if v_num < -360 or v_num > 360 then add_err('$.excitation.phase_offset_deg','out of range -360..360'); end if;
    exception when others then add_err('$.excitation.phase_offset_deg','must be number'); end;
  else
    add_err('$.excitation.phase_offset_deg','missing');
  end if;

  -- duty_cycle: 0..100
  if (v_exc ? 'duty_cycle') then
    begin
      v_num := (v_exc->>'duty_cycle')::numeric;
      if v_num < 0 or v_num > 100 then add_err('$.excitation.duty_cycle','out of range 0..100'); end if;
    exception when others then add_err('$.excitation.duty_cycle','must be number'); end;
  else
    add_err('$.excitation.duty_cycle','missing');
  end if;

  -- nodes items: each must contain id + position {x,y,z} + measures[]
  if jsonb_typeof(v_nodes) = 'array' then
    for v_txt in
      select value::text from jsonb_array_elements(v_nodes)
    loop
      -- just structural checks without expensive deep parsing
      null;
    end loop;

    -- enforce minimal per-node schema by scanning elements
    declare
      n jsonb;
      idx int := 0;
      pos jsonb;
      meas jsonb;
    begin
      for n in select value from jsonb_array_elements(v_nodes)
      loop
        if jsonb_typeof(n) <> 'object' then
          add_err(format('$.nodes[%s]',idx),'must be object');
        else
          if not (n ? 'node_id') then add_err(format('$.nodes[%s].node_id',idx),'missing'); end if;
          if not (n ? 'position') then add_err(format('$.nodes[%s].position',idx),'missing'); end if;
          if not (n ? 'measures') then add_err(format('$.nodes[%s].measures',idx),'missing'); end if;

          pos := n->'position';
          if jsonb_typeof(pos) <> 'object' then
            add_err(format('$.nodes[%s].position',idx),'must be object');
          else
            if not (pos ? 'x') then add_err(format('$.nodes[%s].position.x',idx),'missing'); end if;
            if not (pos ? 'y') then add_err(format('$.nodes[%s].position.y',idx),'missing'); end if;
            if not (pos ? 'z') then add_err(format('$.nodes[%s].position.z',idx),'missing'); end if;
          end if;

          meas := n->'measures';
          if jsonb_typeof(meas) <> 'array' then
            add_err(format('$.nodes[%s].measures',idx),'must be array');
          end if;
        end if;
        idx := idx + 1;
      end loop;
    end;
  end if;

  return jsonb_build_object('ok', (jsonb_array_length(errs)=0), 'errors', errs);
end
$fn$;

-- Router for schema version
create or replace function rgsr.validate_engine_config(p_schema_version int, p_config jsonb)
returns jsonb
language sql
immutable
as $fn$
  select case
    when p_schema_version = 1 then rgsr.validate_engine_config_v1(p_config)
    else jsonb_build_object('ok', false, 'errors', jsonb_build_array(jsonb_build_object('path','$.schema_version','msg','unsupported')))
  end;
$fn$;

-- ------------------------------------------------------------
-- 3) Trigger to enforce validation
-- ------------------------------------------------------------
create or replace function rgsr.tg_engine_configs_validate()
returns trigger
language plpgsql
as $fn$
declare
  v_res jsonb;
begin
  v_res := rgsr.validate_engine_config(new.schema_version, new.config);
  if coalesce((v_res->>'ok')::boolean,false) = false then
    raise exception 'ENGINE_CONFIG_INVALID: %', v_res using errcode='22023';
  end if;

  new.updated_at := now();
  return new;
end
$fn$;

drop trigger if exists trg_engine_configs_validate on rgsr.engine_configs;
create trigger trg_engine_configs_validate
before insert or update on rgsr.engine_configs
for each row execute function rgsr.tg_engine_configs_validate();

-- ------------------------------------------------------------
-- 4) RLS + policies
-- ------------------------------------------------------------
alter table rgsr.engine_configs enable row level security;
alter table rgsr.engine_configs force row level security;

do $do$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname='rgsr' and tablename='engine_configs'
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end
$do$;

create policy engine_configs_read_own on rgsr.engine_configs
for select to authenticated
using (owner_uid = rgsr.actor_uid());

create policy engine_configs_write_own on rgsr.engine_configs
for insert to authenticated
with check (owner_uid = rgsr.actor_uid());

create policy engine_configs_update_own on rgsr.engine_configs
for update to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

create policy engine_configs_delete_own on rgsr.engine_configs
for delete to authenticated
using (owner_uid = rgsr.actor_uid());

create policy engine_configs_admin on rgsr.engine_configs
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

commit;
