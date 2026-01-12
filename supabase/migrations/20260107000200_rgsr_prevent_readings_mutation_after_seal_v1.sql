-- CORE V1: Optional enforcement — prevent tampering with engine_run_readings after sealing
begin;

-- Guard function: blocks any mutation if the parent run is sealed
create or replace function rgsr.guard_engine_run_readings_mutation_after_seal()
returns trigger
language plpgsql
as $$
declare
  v_run_id uuid;
  v_seal text;
begin
  -- Determine target run_id for the row being mutated
  v_run_id := coalesce(NEW.run_id, OLD.run_id);

  if v_run_id is null then
    raise exception 'READINGS_MUTATION_WITHOUT_RUN_ID';
  end if;

  select seal_hash_sha256
    into v_seal
  from rgsr.engine_runs
  where run_id = v_run_id;

  -- If run not found, still block (strong integrity)
  if not found then
    raise exception 'READINGS_MUTATION_RUN_NOT_FOUND run_id=%', v_run_id;
  end if;

  -- If sealed, block all writes
  if v_seal is not null and v_seal <> '' then
    raise exception 'ENGINE_RUN_IS_SEALED: mutations forbidden for run_id=%', v_run_id;
  end if;

  -- otherwise allow
  if (TG_OP = 'DELETE') then
    return OLD;
  else
    return NEW;
  end if;
end;
$$;

comment on function rgsr.guard_engine_run_readings_mutation_after_seal() is
'Blocks INSERT/UPDATE/DELETE on rgsr.engine_run_readings if parent run has seal_hash_sha256 set.';

-- Drop triggers if they already exist (idempotent)
drop trigger if exists tr_engine_run_readings_block_insert_after_seal on rgsr.engine_run_readings;
drop trigger if exists tr_engine_run_readings_block_update_after_seal on rgsr.engine_run_readings;
drop trigger if exists tr_engine_run_readings_block_delete_after_seal on rgsr.engine_run_readings;

-- Create triggers (separate triggers keep behavior explicit)
create trigger tr_engine_run_readings_block_insert_after_seal
before insert on rgsr.engine_run_readings
for each row
execute function rgsr.guard_engine_run_readings_mutation_after_seal();

create trigger tr_engine_run_readings_block_update_after_seal
before update on rgsr.engine_run_readings
for each row
execute function rgsr.guard_engine_run_readings_mutation_after_seal();

create trigger tr_engine_run_readings_block_delete_after_seal
before delete on rgsr.engine_run_readings
for each row
execute function rgsr.guard_engine_run_readings_mutation_after_seal();

commit;
