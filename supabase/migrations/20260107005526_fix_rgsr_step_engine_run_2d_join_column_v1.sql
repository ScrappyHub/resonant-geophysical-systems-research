-- 20260107005526_fix_rgsr_step_engine_run_2d_join_column_v1.sql
-- CANONICAL FIX:
-- Patch rgsr.step_engine_run_2d(uuid,int) to join engine_configs via r.config_id (not r.engine_config_id).
-- Built from pg_get_functiondef() shape, with minimal substitution. NO guessing.

CREATE OR REPLACE FUNCTION rgsr.step_engine_run_2d(
  p_run_id uuid,
  p_steps integer DEFAULT 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $rgsr_fn$
DECLARE
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
BEGIN
  IF p_steps IS NULL OR p_steps < 1 OR p_steps > 2000 THEN
    RAISE EXCEPTION 'STEPS_OUT_OF_RANGE (1..2000)' USING errcode='22023';
  END IF;

  SELECT owner_uid,
         dt_sec,
         COALESCE((stats->>'step_index')::int, 0)
    INTO v_owner, v_dt, v_step
  FROM rgsr.engine_runs
  WHERE run_id = p_run_id;

  IF v_owner IS NULL THEN
    RAISE EXCEPTION 'RUN_NOT_FOUND' USING errcode='22023';
  END IF;

  IF v_owner <> rgsr.actor_uid() AND NOT rgsr.can_write() THEN
    RAISE EXCEPTION 'FORBIDDEN' USING errcode='28000';
  END IF;

  PERFORM rgsr.seed_run_nodes_from_config(p_run_id);

  -- CANONICAL JOIN FIX: ec.config_id = r.config_id
  SELECT ec.config,
         COALESCE(ec.seed, 0)
    INTO v_cfg, v_seed
  FROM rgsr.engine_runs r
  JOIN rgsr.engine_configs ec
    ON ec.config_id = r.config_id
  WHERE r.run_id = p_run_id;

  v_exc   := COALESCE(v_cfg->'excitation', '{}'::jsonb);
  v_freq  := COALESCE(NULLIF(v_exc->>'frequency_hz','')::numeric, 1000);
  v_amp   := COALESCE(NULLIF(v_exc->>'amplitude','')::numeric, 0.25);
  v_phase := COALESCE(NULLIF(v_exc->>'phase_offset_deg','')::numeric, 0);

  FOR v_i IN 1..p_steps LOOP
    v_step := v_step + 1;
    v_t    := v_step * v_dt;

    FOR n IN
      SELECT node_id, position
      FROM rgsr.engine_run_nodes
      WHERE run_id = p_run_id
    LOOP
      px := COALESCE(NULLIF(n.position->>'x','')::numeric, 0);
      py := COALESCE(NULLIF(n.position->>'y','')::numeric, 0);
      pz := COALESCE(NULLIF(n.position->>'z','')::numeric, 0);

      disp  := v_amp * sin(2*pi()*v_freq*v_t + (v_phase*pi()/180) + (px+py+pz)*0.05);
      vel   := (2*pi()*v_freq) * v_amp * cos(2*pi()*v_freq*v_t + (v_phase*pi()/180) + (px+py+pz)*0.05);
      press := 101325 + (disp * 2500);
      temp  := 293.15 + (abs(disp) * 12) + (sin((px*0.01) + (v_t*0.2)) * 1.5);
      res   := abs(disp) * 0.8 + abs(vel) * 0.00001;

      INSERT INTO rgsr.engine_run_readings(
        run_id,
        node_id,
        step_index,
        t_sim_sec,
        readings,
        created_at
      )
      VALUES (
        p_run_id,
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
    END LOOP;
  END LOOP;

  UPDATE rgsr.engine_runs
    SET stats      = COALESCE(stats,'{}'::jsonb) || jsonb_build_object('step_index', v_step),
        updated_at = now()
  WHERE run_id = p_run_id;

  RETURN jsonb_build_object(
    'ok', true,
    'run_id', p_run_id,
    'steps', p_steps,
    'step_index', v_step,
    'readings_written', v_written
  );
END;
$rgsr_fn$;