begin;

create or replace function rgsr.step_engine_run_2d(p_run_id uuid, p_steps integer default 1)
returns jsonb
language plpgsql
security definer
as $function$
declare
  v_owner   uuid;
  v_dt      numeric;
  v_step    int;
  v_i       int;
  v_cfg     jsonb;
  v_exc     jsonb;
  v_freq    numeric;
  v_amp     numeric;
  v_phase   numeric;
  v_seed    bigint;
  v_t       numeric;

  v_step_id uuid;

  n record;

  px numeric;
  py numeric;
  pz numeric;

  temp  numeric;
  press numeric;
  disp  numeric;
  vel   numeric;
  res   numeric;

  v_written int := 0;
begin
  if p_steps is null or p_steps < 1 or p_steps > 2000 then
    raise exception 'STEPS_OUT_OF_RANGE (1..2000)' using errcode='22023';
  end if;

  select owner_uid,
         dt_sec,
         coalesce((stats->>'step_index')::int, 0)
    into v_owner, v_dt, v_step
  from rgsr.engine_runs
  where run_id = p_run_id;

  if v_owner is null then
    raise exception 'RUN_NOT_FOUND' using errcode='22023';
  end if;

  if v_owner <> rgsr.actor_uid() and not rgsr.can_write() then
    raise exception 'FORBIDDEN' using errcode='28000';
  end if;

  perform rgsr.seed_run_nodes_from_config(p_run_id);

  -- CANONICAL JOIN FIX: ec.config_id = r.config_id
  select ec.config,
         coalesce(ec.seed, 0)
    into v_cfg, v_seed
  from rgsr.engine_runs r
  join rgsr.engine_configs ec
    on ec.config_id = r.config_id
  where r.run_id = p_run_id;

  v_exc   := coalesce(v_cfg->'excitation', '{}'::jsonb);
  v_freq  := coalesce(nullif(v_exc->>'frequency_hz','')::numeric, 1000);
  v_amp   := coalesce(nullif(v_exc->>'amplitude','')::numeric, 0.25);
  v_phase := coalesce(nullif(v_exc->>'phase_offset_deg','')::numeric, 0);

  for v_i in 1..p_steps loop
    v_step := v_step + 1;
    v_t    := v_step * v_dt;

    -- -------------------------------------------------------------------------
    -- Gate C (Strong): write the step ledger row FIRST, capture step_id
    -- -------------------------------------------------------------------------
    insert into rgsr.engine_run_steps(run_id, step_no, t_sec, fields, created_at)
    values (
      p_run_id,
      v_step,
      v_t,
      jsonb_build_object(
        'excitation', jsonb_build_object(
          'frequency_hz', v_freq,
          'amplitude', v_amp,
          'phase_offset_deg', v_phase
        )
      ),
      now()
    )
    returning step_id into v_step_id;

    for n in
      select node_id, position
      from rgsr.engine_run_nodes
      where run_id = p_run_id
      order by node_id asc
    loop
      px := coalesce(nullif(n.position->>'x','')::numeric, 0);
      py := coalesce(nullif(n.position->>'y','')::numeric, 0);
      pz := coalesce(nullif(n.position->>'z','')::numeric, 0);

      disp  := v_amp * sin(2*pi()*v_freq*v_t + (v_phase*pi()/180) + (px+py+pz)*0.05);
      vel   := (2*pi()*v_freq) * v_amp * cos(2*pi()*v_freq*v_t + (v_phase*pi()/180) + (px+py+pz)*0.05);
      press := 101325 + (disp * 2500);
      temp  := 293.15 + (abs(disp) * 12) + (sin((px*0.01) + (v_t*0.2)) * 1.5);
      res   := abs(disp) * 0.8 + abs(vel) * 0.00001;

      insert into rgsr.engine_run_readings(
        run_id,
        step_id,
        node_id,
        step_index,
        t_sim_sec,
        readings,
        created_at
      )
      values (
        p_run_id,
        v_step_id,
        n.node_id,
        v_step,
        v_t,
        jsonb_build_object(
          'position', jsonb_build_object('x',px,'y',py,'z',pz),
          'temperature_k', temp,
          'pressure_pa', press,
          'displacement', disp,
          'velocity', vel,
          'resonance_amplitude', res
        ),
        now()
      );

      v_written := v_written + 1;
    end loop;
  end loop;

  update rgsr.engine_runs
    set stats      = coalesce(stats,'{}'::jsonb) || jsonb_build_object('step_index', v_step),
        updated_at = now()
  where run_id = p_run_id;

  return jsonb_build_object(
    'ok', true,
    'run_id', p_run_id,
    'steps', p_steps,
    'step_index', v_step,
    'readings_written', v_written
  );
end;
$function$;

commit;
