-- 20260107033000_fix_rgsr_seed_run_nodes_join_column_v1.sql
-- CANONICAL REPAIR:
-- The existing function returns jsonb. Keep return type identical and only fix the join column.

begin;

drop function if exists rgsr.seed_run_nodes_from_config(uuid);

create function rgsr.seed_run_nodes_from_config(p_run_id uuid)
returns jsonb
language plpgsql
security definer
as $function$
declare
  v_owner uuid;
  v_cfg jsonb;
  v_nodes jsonb;
  v_node jsonb;
  v_node_id text;
begin
  select owner_uid into v_owner
  from rgsr.engine_runs
  where run_id = p_run_id;

  if v_owner is null then
    raise exception 'RUN_NOT_FOUND' using errcode='22023';
  end if;

  if v_owner <> rgsr.actor_uid() and not rgsr.can_write() then
    raise exception 'FORBIDDEN' using errcode='28000';
  end if;

  -- ✅ FIXED: join on r.config_id (not r.engine_config_id)
  select ec.config into v_cfg
  from rgsr.engine_runs r
  join rgsr.engine_configs ec on ec.config_id = r.config_id
  where r.run_id = p_run_id;

  v_nodes := coalesce(v_cfg->'nodes','[]'::jsonb);
  if jsonb_typeof(v_nodes) <> 'array' then
    raise exception 'ENGINE_CONFIG_INVALID_NODES' using errcode='22023';
  end if;

  for v_node in select value from jsonb_array_elements(v_nodes)
  loop
    v_node_id := nullif(v_node->>'node_id','');
    if v_node_id is null then
      continue;
    end if;

    insert into rgsr.engine_run_nodes(run_id, node_id, position, measures, metadata)
    values (
      p_run_id,
      v_node_id,
      coalesce(v_node->'position','{}'::jsonb),
      coalesce(array(select jsonb_array_elements_text(coalesce(v_node->'measures','[]'::jsonb))), '{}'::text[]),
      coalesce(v_node->'metadata','{}'::jsonb)
    )
    on conflict (run_id, node_id) do nothing;
  end loop;

  return jsonb_build_object('ok', true, 'run_id', p_run_id);
end
$function$;

commit;
