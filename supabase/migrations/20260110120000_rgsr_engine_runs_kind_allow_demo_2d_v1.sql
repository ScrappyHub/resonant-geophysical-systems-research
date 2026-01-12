begin;

-- Expand allowed engine kinds to include DEMO_2D
-- Current: CHECK (engine_kind = ANY (ARRAY['2D','3D']))
-- New:     CHECK (engine_kind = ANY (ARRAY['2D','3D','DEMO_2D']))

do $$
begin
  if exists (
    select 1
    from pg_constraint c
    where c.connamespace = 'rgsr'::regnamespace
      and c.conrelid = 'rgsr.engine_runs'::regclass
      and c.conname = 'engine_runs_kind_chk'
      and position('DEMO_2D' in pg_get_constraintdef(c.oid)) > 0
  ) then
    raise notice 'engine_runs_kind_chk already allows DEMO_2D (noop)';
    return;
  end if;

  alter table rgsr.engine_runs drop constraint if exists engine_runs_kind_chk;

  alter table rgsr.engine_runs
    add constraint engine_runs_kind_chk
    check (engine_kind = any (array['2D'::text, '3D'::text, 'DEMO_2D'::text]));

  raise notice 'engine_runs_kind_chk updated to include DEMO_2D';
end
$$;

commit;
