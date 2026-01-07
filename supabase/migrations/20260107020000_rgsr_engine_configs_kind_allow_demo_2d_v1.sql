-- 20260107020000_rgsr_engine_configs_kind_allow_demo_2d_v1.sql
-- CANONICAL: eliminate manual STOP placeholders.
-- Goal: ensure rgsr.engine_configs.config_kind allows 'DEMO_2D' in addition to existing allowed values.

begin;

do $$
declare
  v_def text;
begin
  -- Get existing constraint definition (authoritative)
  select pg_get_constraintdef(c.oid)
    into v_def
  from pg_constraint c
  where c.conname = 'engine_configs_kind_chk'
    and c.conrelid = 'rgsr.engine_configs'::regclass;

  if v_def is null then
    raise exception 'engine_configs_kind_chk not found on rgsr.engine_configs';
  end if;

  -- If DEMO_2D already allowed, do nothing (idempotent).
  if v_def ilike '%DEMO_2D%' then
    raise notice 'engine_configs_kind_chk already allows DEMO_2D; no change.';
    return;
  end if;

  -- We only support the canonical form you already printed:
  -- CHECK ((config_kind = ANY (ARRAY['demo'::text, 'workbench'::text])))
  if v_def not ilike '%config_kind = any%' or v_def not ilike '%array[%' then
    raise exception 'Unexpected engine_configs_kind_chk form: %', v_def;
  end if;

  -- Replace the closing "]))" to insert DEMO_2D before it.
  -- Example:
  -- CHECK ((config_kind = ANY (ARRAY['demo'::text, 'workbench'::text])))
  -- becomes:
  -- CHECK ((config_kind = ANY (ARRAY['demo'::text, 'workbench'::text, 'DEMO_2D'::text])))
  v_def := replace(v_def, ']))', ', ''DEMO_2D''::text]))');

  execute 'alter table rgsr.engine_configs drop constraint if exists engine_configs_kind_chk';
  execute 'alter table rgsr.engine_configs add constraint engine_configs_kind_chk check ' ||
          substring(v_def from position('CHECK' in v_def) + 5);

  raise notice 'engine_configs_kind_chk updated to include DEMO_2D.';
end $$;

commit;
