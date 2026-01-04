-- 20260103201600_rgsr_engine_runs_fk_shadow_safe_repair.sql
-- Local/shadow-safe: ensure rgsr.engine_runs has a config reference and a valid FK to rgsr.engine_configs(config_id).
-- Strategy:
--  - If engine_runs.engine_config_id exists -> FK it to engine_configs(config_id)
--  - Else if engine_runs.config_id exists -> FK it to engine_configs(config_id)
--  - Else add engine_config_id uuid -> FK it

do $$
begin
  raise notice 'RGSR engine_runs FK shadow-safe repair: start';
end
$$;

do $$
declare
  has_engine_config_id boolean;
  has_config_id        boolean;
  fk_name text := 'engine_runs_engine_config_ref_fkey';
  ref_col text;
begin
  select exists (
    select 1 from information_schema.columns
    where table_schema='rgsr' and table_name='engine_runs' and column_name='engine_config_id'
  ) into has_engine_config_id;

  select exists (
    select 1 from information_schema.columns
    where table_schema='rgsr' and table_name='engine_runs' and column_name='config_id'
  ) into has_config_id;

  if has_engine_config_id then
    ref_col := 'engine_config_id';
  elsif has_config_id then
    ref_col := 'config_id';
  else
    execute 'alter table rgsr.engine_runs add column if not exists engine_config_id uuid';
    ref_col := 'engine_config_id';
  end if;

  -- Drop any prior version of our canonical FK (safe)
  if exists (
    select 1
    from information_schema.table_constraints tc
    where tc.constraint_schema='rgsr'
      and tc.table_name='engine_runs'
      and tc.constraint_name=fk_name
      and tc.constraint_type='FOREIGN KEY'
  ) then
    execute format('alter table rgsr.engine_runs drop constraint %I', fk_name);
  end if;

  -- Add canonical FK to engine_configs(config_id)
  execute format(
    'alter table rgsr.engine_runs add constraint %I foreign key (%I) references rgsr.engine_configs(config_id) on delete restrict',
    fk_name, ref_col
  );

  raise notice 'RGSR engine_runs FK shadow-safe repair: using column %', ref_col;
end
$$;

do $$
begin
  raise notice 'RGSR engine_runs FK shadow-safe repair: done';
end
$$;