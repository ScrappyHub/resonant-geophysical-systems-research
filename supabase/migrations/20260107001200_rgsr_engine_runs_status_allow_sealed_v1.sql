begin;

do $$
declare
  v_con_oid oid;
  v_def text;
  v_allow_null boolean;
  v_vals text[];
  v_vals_with_sealed text[];
  v_list_sql text;
  v_new_check text;
begin
  -- locate the constraint on rgsr.engine_runs
  select c.oid, pg_get_constraintdef(c.oid)
    into v_con_oid, v_def
  from pg_constraint c
  where c.conname = 'engine_runs_status_chk'
    and c.conrelid = 'rgsr.engine_runs'::regclass;

  if v_con_oid is null then
    raise exception 'ENGINE_RUNS_STATUS_CHK_NOT_FOUND';
  end if;

  -- if it already allows 'sealed', do nothing
  if v_def ilike '%''sealed''%' then
    raise notice 'engine_runs_status_chk already allows sealed; skipping';
    return;
  end if;

  -- detect whether old constraint allowed NULLs (best-effort)
  v_allow_null := (v_def ilike '%is null%');

  -- extract quoted literals from the existing CHECK definition
  -- (works for forms like: status IN ('created','running',...))
  select array_agg(distinct m.val order by m.val)
    into v_vals
  from (
    select (regexp_matches(v_def, '''([^'']+)''', 'g'))[1] as val
  ) m;

  if v_vals is null or array_length(v_vals, 1) is null then
    raise exception 'FAILED_TO_PARSE_STATUS_LITERALS_FROM_CONSTRAINT_DEF: %', v_def;
  end if;

  -- append sealed if missing
  if not ('sealed' = any(v_vals)) then
    v_vals_with_sealed := array_append(v_vals, 'sealed');
  else
    v_vals_with_sealed := v_vals;
  end if;

  -- build SQL list: 'a','b','c'
  select string_agg(quote_literal(x), ',')
    into v_list_sql
  from unnest(v_vals_with_sealed) x;

  if v_allow_null then
    v_new_check := format('(status is null or status in (%s))', v_list_sql);
  else
    v_new_check := format('(status in (%s))', v_list_sql);
  end if;

  -- replace constraint
  execute 'alter table rgsr.engine_runs drop constraint engine_runs_status_chk';
  execute format('alter table rgsr.engine_runs add constraint engine_runs_status_chk check %s', v_new_check);

  raise notice 'engine_runs_status_chk updated to allow sealed';
end $$;

commit;
