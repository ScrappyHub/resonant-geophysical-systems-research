begin;

-- AFTER-SEAL GUARDS (IDEMPOTENT)
-- Assumes these guard functions exist:
--   rgsr.guard_engine_runs_mutation_after_seal()
--   rgsr.guard_engine_run_readings_mutation_after_seal()
--   rgsr.guard_engine_run_nodes_mutation_after_seal()

do $$
declare
  fn_runs     regproc;
  fn_readings regproc;
  fn_nodes    regproc;
begin
  fn_runs     := to_regproc('rgsr.guard_engine_runs_mutation_after_seal');
  fn_readings := to_regproc('rgsr.guard_engine_run_readings_mutation_after_seal');
  fn_nodes    := to_regproc('rgsr.guard_engine_run_nodes_mutation_after_seal');

  -- ENGINE RUNS (block UPDATE/DELETE after seal)
  if fn_runs is not null and to_regclass('rgsr.engine_runs') is not null then
    execute 'drop trigger if exists tg_guard_after_seal__engine_runs on rgsr.engine_runs';
    execute 'create trigger tg_guard_after_seal__engine_runs
             before update or delete on rgsr.engine_runs
             for each row execute function rgsr.guard_engine_runs_mutation_after_seal()';
  end if;

  -- ENGINE RUN READINGS (block INSERT/UPDATE/DELETE after seal)
  if fn_readings is not null and to_regclass('rgsr.engine_run_readings') is not null then
    execute 'drop trigger if exists tg_guard_after_seal__engine_run_readings on rgsr.engine_run_readings';
    execute 'create trigger tg_guard_after_seal__engine_run_readings
             before insert or update or delete on rgsr.engine_run_readings
             for each row execute function rgsr.guard_engine_run_readings_mutation_after_seal()';
  end if;

  -- ENGINE RUN NODES (block INSERT/UPDATE/DELETE after seal)
  if fn_nodes is not null and to_regclass('rgsr.engine_run_nodes') is not null then
    execute 'drop trigger if exists tg_guard_after_seal__engine_run_nodes on rgsr.engine_run_nodes';
    execute 'create trigger tg_guard_after_seal__engine_run_nodes
             before insert or update or delete on rgsr.engine_run_nodes
             for each row execute function rgsr.guard_engine_run_nodes_mutation_after_seal()';
  end if;

  -- ENGINE RUN NODES SNAPSHOT (block INSERT/UPDATE/DELETE after seal)
  if fn_nodes is not null and to_regclass('rgsr.engine_run_nodes_snapshot') is not null then
    execute 'drop trigger if exists tg_guard_after_seal__engine_run_nodes_snapshot on rgsr.engine_run_nodes_snapshot';
    execute 'create trigger tg_guard_after_seal__engine_run_nodes_snapshot
             before insert or update or delete on rgsr.engine_run_nodes_snapshot
             for each row execute function rgsr.guard_engine_run_nodes_mutation_after_seal()';
  end if;
end
$$;

comment on schema rgsr is
  'RGSR: After-seal guards enforced via triggers + guard functions (mutation forbidden post-seal).';

commit;