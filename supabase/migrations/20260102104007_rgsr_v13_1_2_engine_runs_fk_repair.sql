-- ============================================================
-- RGSR v13.1.2 — ENGINE_RUNS FK REPAIR (engine_config_id -> engine_configs.config_id)
-- - Keep column name engine_config_id (already deployed)
-- - Fix FK target to rgsr.engine_configs(config_id)
-- ============================================================

begin;

create schema if not exists rgsr;

-- Drop any existing FK on engine_runs.engine_config_id (name unknown)
do $do$
declare r record;
begin
  for r in
    select c.conname
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname='rgsr'
      and t.relname='engine_runs'
      and c.contype='f'
  loop
    execute format('alter table rgsr.engine_runs drop constraint if exists %I', r.conname);
  end loop;
end
$do$;

-- Add the canonical FK (idempotent via drop+add)
alter table rgsr.engine_runs
  add constraint engine_runs_engine_config_id_fkey
  foreign key (engine_config_id)
  references rgsr.engine_configs(config_id)
  on delete restrict;

create index if not exists ix_engine_runs_owner_time
  on rgsr.engine_runs(owner_uid, created_at desc);

create index if not exists ix_engine_runs_config
  on rgsr.engine_runs(engine_config_id);

commit;
