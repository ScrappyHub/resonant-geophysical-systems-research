begin;

-- =============================================================================
-- RGSR Gate C (Strong): Steps are the ledger; readings attach to step_id
-- Existing canonical schema:
--   rgsr.engine_run_steps: (step_id, run_id, step_no, t_sec, fields, created_at)
--   rgsr.engine_run_readings: (reading_id, run_id, node_id, step_index, t_sim_sec, readings, created_at)
-- =============================================================================

-- 1) Ensure step_id exists on readings (nullable for now)
do $$
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema='rgsr'
      and table_name='engine_run_readings'
      and column_name='step_id'
  ) then
    alter table rgsr.engine_run_readings
      add column step_id uuid;
  end if;
end
$$;

-- 2) Add FK readings.step_id -> steps.step_id (deferrable)
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where connamespace='rgsr'::regnamespace
      and conname='engine_run_readings_step_fk'
  ) then
    alter table rgsr.engine_run_readings
      add constraint engine_run_readings_step_fk
      foreign key (step_id)
      references rgsr.engine_run_steps(step_id)
      deferrable initially deferred;
  end if;
end
$$;

-- 3) Helpful index for step join
create index if not exists ix_engine_run_readings_step_id
  on rgsr.engine_run_readings(step_id);

-- 4) Ensure uniqueness constraint exists for the ledger (run_id, step_no)
-- NOTE: you already have engine_run_steps_unique UNIQUE (run_id, step_no)
-- We keep your existing constraint name; do NOT create a duplicate.
-- If it ever doesn't exist, add it.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where connamespace='rgsr'::regnamespace
      and conname in ('engine_run_steps_unique','engine_run_steps_run_step_ux')
  ) then
    alter table rgsr.engine_run_steps
      add constraint engine_run_steps_unique unique (run_id, step_no);
  end if;
end
$$;

-- 5) Helpful index for ordering/lookup
create index if not exists ix_engine_run_steps_run_step_no
  on rgsr.engine_run_steps(run_id, step_no);

commit;
