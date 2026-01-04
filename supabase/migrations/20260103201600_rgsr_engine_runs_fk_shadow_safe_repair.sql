-- 20260103201600_rgsr_engine_runs_fk_shadow_safe_repair.sql
-- Local/shadow-safe: ensure rgsr.engine_runs has a config reference and a valid FK to rgsr.engine_configs(config_id).
-- Strategy:
--  - If engine_runs.engine_config_id exists -> FK it to engine_configs(config_id)
--  - Else if engine_runs.config_id exists -> FK it to engine_configs(config_id)
--  - Else add engine_config_id uuid -> FK it

do \$\$
declare
  has_engine_runs boolean;
  has_engine_configs boolean;
  has_engine_config_id boolean;
  has_config_id boolean;
  fk_exists boolean;
  fk_name text;
  fk_col text;
begin
  select exists (
    select 1 from information_schema.tables
    where table_schema='rgsr' and table_name='engine_runs'
  ) into has_engine_runs;

  select exists (
    select 1 from information_schema.tables
    where table_schema='rgsr' and table_name='engine_configs'
  ) into has_engine_configs;

  if not has_engine_runs or not has_engine_configs then
    raise notice 'FK repair skipped: engine_runs or engine_configs missing';
    return;
  end if;

  select exists (
    select 1 from information_schema.columns
    where table_schema='rgsr' and table_name='engine_runs' and column_name='engine_config_id'
  ) into has_engine_config_id;

  select exists (
    select 1 from information_schema.columns
    where table_schema='rgsr' and table_name='engine_runs' and column_name='config_id'
  ) into has_config_id;

  if not has_engine_config_id and not has_config_id then
    raise notice 'Adding rgsr.engine_runs.engine_config_id uuid';
    execute 'alter table rgsr.engine_runs add column engine_config_id uuid';
    has_engine_config_id := true;
  end if;

  if has_engine_config_id then
    fk_col := 'engine_config_id';
    fk_name := 'engine_runs_engine_config_id_fkey';
  else
    fk_col := 'config_id';
    fk_name := 'engine_runs_config_id_fkey';
  end if;

  select exists (
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname='rgsr'
      and t.relname='engine_runs'
      and c.conname=fk_name
  ) into fk_exists;

  if fk_exists then
    raise notice 'FK already exists: %', fk_name;
    return;
  end if;

  raise notice 'Adding FK % on column %', fk_name, fk_col;

  execute format(
    'alter table rgsr.engine_runs add constraint %I foreign key (%I) references rgsr.engine_configs(config_id) on delete restrict',
    fk_name, fk_col
  );

end
\$\$;
