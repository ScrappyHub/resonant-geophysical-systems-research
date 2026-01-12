begin;

-- RGSR: After-seal guard coverage invariant (SQL-only, CI-safe)
-- Purpose:
--   - This migration is intentionally a NO-OP on schema objects.
--   - It *asserts* that required after-seal guard triggers exist on the core post-seal tables.
--
-- If you add new post-seal tables later, add them to this assertion list.

do $$
declare
  missing text[];
begin
  missing := array_remove(array[
    case when to_regclass('rgsr.engine_runs') is not null
          and exists (select 1 from pg_trigger t
                      where t.tgrelid = 'rgsr.engine_runs'::regclass
                        and not t.tgisinternal
                        and t.tgname in ('tr_engine_runs_block_update_after_seal','tr_engine_runs_block_delete_after_seal','tg_guard_after_seal__engine_runs'))
         then null else 'rgsr.engine_runs' end,

    case when to_regclass('rgsr.engine_run_readings') is not null
          and exists (select 1 from pg_trigger t
                      where t.tgrelid = 'rgsr.engine_run_readings'::regclass
                        and not t.tgisinternal
                        and t.tgname in ('tr_engine_run_readings_block_insert_after_seal','tr_engine_run_readings_block_update_after_seal','tr_engine_run_readings_block_delete_after_seal','tg_guard_after_seal__engine_run_readings'))
         then null else 'rgsr.engine_run_readings' end,

    case when to_regclass('rgsr.engine_run_nodes') is not null
          and exists (select 1 from pg_trigger t
                      where t.tgrelid = 'rgsr.engine_run_nodes'::regclass
                        and not t.tgisinternal
                        and t.tgname in ('tr_engine_run_nodes_block_insert_after_seal','tr_engine_run_nodes_block_update_after_seal','tr_engine_run_nodes_block_delete_after_seal','tg_guard_after_seal__engine_run_nodes'))
         then null else 'rgsr.engine_run_nodes' end,

    case when to_regclass('rgsr.engine_run_nodes_snapshot') is not null
          and exists (select 1 from pg_trigger t
                      where t.tgrelid = 'rgsr.engine_run_nodes_snapshot'::regclass
                        and not t.tgisinternal
                        and t.tgname in ('tr_engine_run_nodes_snapshot_block_insert_after_seal','tr_engine_run_nodes_snapshot_block_update_after_seal','tr_engine_run_nodes_snapshot_block_delete_after_seal','tg_guard_after_seal__engine_run_nodes_snapshot'))
         then null else 'rgsr.engine_run_nodes_snapshot' end
  ], null);

  if array_length(missing, 1) is not null then
    raise exception 'Missing after-seal guard triggers on: %', missing;
  end if;

  raise notice 'After-seal guard coverage OK';
end
$$;

commit;