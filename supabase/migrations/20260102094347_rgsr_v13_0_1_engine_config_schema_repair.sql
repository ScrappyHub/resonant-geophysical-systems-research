-- ============================================================
-- RGSR v13.0.1 — ENGINE CONFIG SCHEMA (REPAIR)
-- Fix: remove illegal nested function definition in plpgsql
-- ============================================================

begin;

create schema if not exists rgsr;

-- 1) engine_configs (validated JSON)
create table if not exists rgsr.engine_configs (
  config_id uuid primary key default gen_random_uuid(),
  owner_uid uuid not null references auth.users(id) on delete restrict,
  config_kind text not null default 'workbench', -- demo/workbench
  schema_version int not null default 1,
  seed bigint not null default 1,
  config jsonb not null default '{}'::jsonb,
  title text not null default '',
  description text not null default '',
  tags text[] not null default '{}'::text[],
  metadata jsonb not null default '{}'::jsonb,
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

-- 2) Validator v1 (no nested helper funcs)
create or replace function rgsr.validate_engine_config_v1(p_config jsonb)
returns jsonb
language plpgsql
immutable
as $fn$
declare
  errs jsonb := '[]'::jsonb;

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
    errs := errs || jsonb_build_array(jsonb_build_object('path', '$', 'msg', 'config must be a JSON object'));
    return jsonb_build_object('ok', false, 'errors', errs);
  end if;

  -- required top-level keys
  if not (p_config ? 'domains')        then errs := errs || jsonb_build_array(jsonb_build_object('path','$.domains','msg','missing')); end if;
  if not (p_config ? 'geometry')       then errs := errs || jsonb_build_array(jsonb_build_object('path','$.geometry','msg','missing')); end if;
  if not (p_config ? 'excitation')     then errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation','msg','missing')); end if;
  if not (p_config ? 'materials')      then errs := errs || jsonb_build_array(jsonb_build_object('path','$.materials','msg','missing')); end if;
  if not (p_config ? 'water')          then errs := errs || jsonb_build_array(jsonb_build_object('path','$.water','msg','missing')); end if;
  if not (p_config ? 'thermal')        then errs := errs || jsonb_build_array(jsonb_build_object('path','$.thermal','msg','missing')); end if;
  if not (p_config ? 'atmosphere')     then errs := errs || jsonb_build_array(jsonb_build_object('path','$.atmosphere','msg','missing')); end if;
  if not (p_config ? 'electromagnetic')then errs := errs || jsonb_build_array(jsonb_build_object('path','$.electromagnetic','msg','missing')); end if;
  if not (p_config ? 'nodes')          then errs := errs || jsonb_build_array(jsonb_build_object('path','$.nodes','msg','missing')); end if;

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

  if jsonb_typeof(v_domains) <> 'object' then errs := errs || jsonb_build_array(jsonb_build_object('path','$.domains','msg','must be object')); end if;

  if jsonb_typeof(v_geom) <> 'object' then
    errs := errs || jsonb_build_array(jsonb_build_object('path','$.geometry','msg','must be object'));
  else
    if not (v_geom ? 'kind') then errs := errs || jsonb_build_array(jsonb_build_object('path','$.geometry.kind','msg','missing')); end if;
  end if;

  if jsonb_typeof(v_exc) <> 'object' then errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation','msg','must be object')); end if;
  if jsonb_typeof(v_mat) <> 'object' then errs := errs || jsonb_build_array(jsonb_build_object('path','$.materials','msg','must be object')); end if;
  if jsonb_typeof(v_water) <> 'object' then errs := errs || jsonb_build_array(jsonb_build_object('path','$.water','msg','must be object')); end if;
  if jsonb_typeof(v_therm) <> 'object' then errs := errs || jsonb_build_array(jsonb_build_object('path','$.thermal','msg','must be object')); end if;
  if jsonb_typeof(v_atm) <> 'object' then errs := errs || jsonb_build_array(jsonb_build_object('path','$.atmosphere','msg','must be object')); end if;
  if jsonb_typeof(v_em) <> 'object' then errs := errs || jsonb_build_array(jsonb_build_object('path','$.electromagnetic','msg','must be object')); end if;

  if jsonb_typeof(v_nodes) <> 'array' then errs := errs || jsonb_build_array(jsonb_build_object('path','$.nodes','msg','must be array')); end if;

  -- excitation ranges
  if jsonb_typeof(v_exc) = 'object' then
    if (v_exc ? 'frequency_hz') then
      begin
        v_num := (v_exc->>'frequency_hz')::numeric;
        if v_num < 0 or v_num > 50000 then errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.frequency_hz','msg','out of range 0..50000')); end if;
      exception when others then
        errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.frequency_hz','msg','must be number'));
      end;
    else
      errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.frequency_hz','msg','missing'));
    end if;

    if (v_exc ? 'amplitude') then
      begin
        v_num := (v_exc->>'amplitude')::numeric;
        if v_num < 0 or v_num > 1 then errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.amplitude','msg','out of range 0..1')); end if;
      exception when others then
        errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.amplitude','msg','must be number'));
      end;
    else
      errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.amplitude','msg','missing'));
    end if;

    if (v_exc ? 'waveform') then
      v_txt := lower(nullif(v_exc->>'waveform',''));
      if v_txt not in ('sine','square','triangle','noise','pulse') then
        errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.waveform','msg','invalid (sine|square|triangle|noise|pulse)'));
      end if;
    else
      errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.waveform','msg','missing'));
    end if;

    if (v_exc ? 'phase_offset_deg') then
      begin
        v_num := (v_exc->>'phase_offset_deg')::numeric;
        if v_num < -360 or v_num > 360 then errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.phase_offset_deg','msg','out of range -360..360')); end if;
      exception when others then
        errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.phase_offset_deg','msg','must be number'));
      end;
    else
      errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.phase_offset_deg','msg','missing'));
    end if;

    if (v_exc ? 'duty_cycle') then
      begin
        v_num := (v_exc->>'duty_cycle')::numeric;
        if v_num < 0 or v_num > 100 then errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.duty_cycle','msg','out of range 0..100')); end if;
      exception when others then
        errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.duty_cycle','msg','must be number'));
      end;
    else
      errs := errs || jsonb_build_array(jsonb_build_object('path','$.excitation.duty_cycle','msg','missing'));
    end if;
  end if;

  -- per-node minimal schema
  if jsonb_typeof(v_nodes) = 'array' then
    declare
      n jsonb;
      idx int := 0;
      pos jsonb;
      meas jsonb;
    begin
      for n in select value from jsonb_array_elements(v_nodes)
      loop
        if jsonb_typeof(n) <> 'object' then
          errs := errs || jsonb_build_array(jsonb_build_object('path', format('$.nodes[%s]',idx), 'msg','must be object'));
        else
          if not (n ? 'node_id') then errs := errs || jsonb_build_array(jsonb_build_object('path', format('$.nodes[%s].node_id',idx), 'msg','missing')); end if;
          if not (n ? 'position') then errs := errs || jsonb_build_array(jsonb_build_object('path', format('$.nodes[%s].position',idx), 'msg','missing')); end if;
          if not (n ? 'measures') then errs := errs || jsonb_build_array(jsonb_build_object('path', format('$.nodes[%s].measures',idx), 'msg','missing')); end if;

          pos := n->'position';
          if jsonb_typeof(pos) <> 'object' then
            errs := errs || jsonb_build_array(jsonb_build_object('path', format('$.nodes[%s].position',idx), 'msg','must be object'));
          else
            if not (pos ? 'x') then errs := errs || jsonb_build_array(jsonb_build_object('path', format('$.nodes[%s].position.x',idx), 'msg','missing')); end if;
            if not (pos ? 'y') then errs := errs || jsonb_build_array(jsonb_build_object('path', format('$.nodes[%s].position.y',idx), 'msg','missing')); end if;
            if not (pos ? 'z') then errs := errs || jsonb_build_array(jsonb_build_object('path', format('$.nodes[%s].position.z',idx), 'msg','missing')); end if;
          end if;

          meas := n->'measures';
          if jsonb_typeof(meas) <> 'array' then
            errs := errs || jsonb_build_array(jsonb_build_object('path', format('$.nodes[%s].measures',idx), 'msg','must be array'));
          end if;
        end if;

        idx := idx + 1;
      end loop;
    end;
  end if;

  return jsonb_build_object('ok', (jsonb_array_length(errs)=0), 'errors', errs);
end
$fn$;

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

-- 3) enforce validation via trigger
create or replace function rgsr.tg_engine_configs_validate()
returns trigger
language plpgsql
as $fn$
declare v_res jsonb;
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

-- 4) RLS + policies
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

create policy engine_configs_insert_own on rgsr.engine_configs
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
