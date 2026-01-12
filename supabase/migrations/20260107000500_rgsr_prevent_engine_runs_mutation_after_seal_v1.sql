begin;

-- Guard: once sealed (seal_hash_sha256 is NOT NULL) the engine_runs row is immutable.
create or replace function rgsr.guard_engine_runs_mutation_after_seal()
returns trigger
language plpgsql
security definer
set search_path = rgsr, public
as $fn$
declare
  v_seal text;
begin
  -- Determine the run_id for the row being touched
  -- UPDATE/DELETE have OLD; INSERT has NEW.
  if tg_op = 'INSERT' then
    -- inserts are allowed (run isn't sealed yet)
    return new;
  end if;

  if old.run_id is null then
    raise exception 'ENGINE_RUN_ID_MISSING';
  end if;

  select seal_hash_sha256
    into v_seal
  from rgsr.engine_runs
  where run_id = old.run_id;

  if v_seal is not null then
    raise exception 'ENGINE_RUN_IS_SEALED: mutations forbidden for run_id=%', old.run_id;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;

  return new;
end
$fn$;

comment on function rgsr.guard_engine_runs_mutation_after_seal() is
'Blocks UPDATE/DELETE on rgsr.engine_runs once seal_hash_sha256 is populated (sealed run).';

-- Replace triggers idempotently
drop trigger if exists tr_engine_runs_block_update_after_seal on rgsr.engine_runs;
drop trigger if exists tr_engine_runs_block_delete_after_seal on rgsr.engine_runs;

create trigger tr_engine_runs_block_update_after_seal
before update on rgsr.engine_runs
for each row
execute function rgsr.guard_engine_runs_mutation_after_seal();

create trigger tr_engine_runs_block_delete_after_seal
before delete on rgsr.engine_runs
for each row
execute function rgsr.guard_engine_runs_mutation_after_seal();

commit;
