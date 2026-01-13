-- rgsr_ab_compare.sql
-- Canonical sanity: A/B compare returns ok=true when comparing a run to itself.

do $$
declare
  v_run uuid;
  v_out jsonb;
begin
  -- create a deterministic run using your existing determinism test pattern,
  -- or reuse the last determinism test's run if you prefer.
  -- For now, we assume determinism test already seeds & seals one run and you can select it.
  select er.run_id
    into v_run
  from rgsr.engine_runs er
  where er.status = 'sealed'
  order by er.created_at desc
  limit 1;

  if v_run is null then
    raise exception 'AB compare test: no sealed run found';
  end if;

  v_out := rgsr.ab_compare_engine_runs(v_run, v_run);

  if coalesce((v_out->>'ok')::boolean, false) is distinct from true then
    raise exception 'AB compare test: expected ok=true, got %', v_out;
  end if;

  if coalesce((v_out#>>'{comparison,a_vs_b_hash_equal}')::boolean, false) is distinct from true then
    raise exception 'AB compare test: expected a_vs_b_hash_equal=true, got %', v_out;
  end if;

  raise notice 'AB compare test: PASS run=% out=%', v_run, v_out;
end $$;
