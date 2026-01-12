begin;

-- =============================================================================
-- RGSR: Hashes commit to header + config + nodes + readings
-- =============================================================================

create or replace function rgsr.engine_run_hash_sha256(p_run_id uuid)
returns text
language plpgsql
stable
as $$
declare
  v_header text;
  v_cfg_text text;
  v_nodes_hash text;
  v_readings_hash text;
  v_payload text;
begin
  -- Header (stable string)
  select
    'run=' || r.run_id::text
    || '|kind=' || r.engine_kind
    || '|tick_hz=' || r.tick_hz::text
    || '|dt_sec=' || r.dt_sec::text
    || '|max_steps=' || r.max_steps::text
    || '|config_id=' || r.config_id::text
  into v_header
  from rgsr.engine_runs r
  where r.run_id = p_run_id;

  if v_header is null then
    raise exception 'RUN_NOT_FOUND' using errcode='22023';
  end if;

  -- Config text (jsonb::text is canonicalized in Postgres)
  select coalesce(ec.config::text, '{}'::text)
  into v_cfg_text
  from rgsr.engine_runs r
  join rgsr.engine_configs ec on ec.config_id = r.config_id
  where r.run_id = p_run_id;

  v_cfg_text := coalesce(v_cfg_text, '{}'::text);

  -- Nodes hash (you already have this function)
  v_nodes_hash := coalesce(rgsr.engine_run_nodes_hash_sha256(p_run_id), '');

  -- Readings hash (same behavior as before: empty -> sha256(''))
  select encode(
    extensions.digest(
      convert_to(
        coalesce(
          string_agg(
            (r.step_index::text) || ':' ||
            (r.node_id::text)    || ':' ||
            coalesce(r.t_sim_sec::text, '') || ':' ||
            coalesce(r.readings::text, ''),
            '|' order by r.step_index asc, r.node_id asc, r.reading_id asc
          ),
          ''
        ),
        'utf8'
      ),
      'sha256'
    ),
    'hex'
  )
  into v_readings_hash
  from rgsr.engine_run_readings r
  where r.run_id = p_run_id;

  v_readings_hash := coalesce(v_readings_hash, encode(extensions.digest(convert_to('', 'utf8'), 'sha256'), 'hex'));

  -- Envelope (now never empty)
  v_payload :=
    v_header
    || '|cfg=' || v_cfg_text
    || '|nodes=' || v_nodes_hash
    || '|readings=' || v_readings_hash;

  return encode(
    extensions.digest(convert_to(v_payload, 'utf8'), 'sha256'),
    'hex'
  );
end;
$$;


create or replace function rgsr.replay_engine_run_hash_sha256(p_run_id uuid)
returns text
language plpgsql
stable
security definer
set search_path to 'rgsr', 'public'
as $$
declare
  v_dt      numeric;
  v_cfg     jsonb;
  v_exc     jsonb;
  v_freq    numeric;
  v_amp     numeric;
  v_phase   numeric;

  v_max_step int;
  v_step     int;
  v_t        numeric;

  n record;

  px numeric;
  py numeric;
  pz numeric;

  temp  numeric;
  press numeric;
  disp  numeric;
  vel   numeric;
  res   numeric;

  v_parts text[] := array[]::text[];
  v_all   text;

  v_header text;
  v_cfg_text text;
  v_nodes_hash text;
  v_readings_hash text;
  v_payload text;

  rrec record;
begin
  -- Pull run header fields + dt
  select run_id, engine_kind, tick_hz, dt_sec, max_steps, config_id
    into rrec
  from rgsr.engine_runs
  where run_id = p_run_id;

  if rrec.dt_sec is null then
    raise exception 'RUN_NOT_FOUND' using errcode='22023';
  end if;

  v_dt := rrec.dt_sec;

  v_header :=
    'run=' || rrec.run_id::text
    || '|kind=' || rrec.engine_kind
    || '|tick_hz=' || rrec.tick_hz::text
    || '|dt_sec=' || rrec.dt_sec::text
    || '|max_steps=' || rrec.max_steps::text
    || '|config_id=' || rrec.config_id::text;

  -- Config
  select ec.config
    into v_cfg
  from rgsr.engine_runs r
  join rgsr.engine_configs ec
    on ec.config_id = r.config_id
  where r.run_id = p_run_id;

  v_cfg := coalesce(v_cfg, '{}'::jsonb);
  v_cfg_text := v_cfg::text;

  v_exc   := coalesce(v_cfg->'excitation', '{}'::jsonb);
  v_freq  := coalesce(nullif(v_exc->>'frequency_hz','')::numeric, 1000);
  v_amp   := coalesce(nullif(v_exc->>'amplitude','')::numeric, 0.25);
  v_phase := coalesce(nullif(v_exc->>'phase_offset_deg','')::numeric, 0);

  -- Nodes hash
  v_nodes_hash := coalesce(rgsr.engine_run_nodes_hash_sha256(p_run_id), '');

  -- Determine how many steps actually exist in sealed readings
  select coalesce(max(step_index), 0)
    into v_max_step
  from rgsr.engine_run_readings
  where run_id = p_run_id;

  if not exists (select 1 from rgsr.engine_run_nodes where run_id = p_run_id) then
    raise exception 'REPLAY_NODES_MISSING run_id=%', p_run_id using errcode='22023';
  end if;

  if v_max_step <= 0 then
    -- readings hash for empty set
    v_readings_hash := encode(extensions.digest(convert_to('', 'utf8'), 'sha256'), 'hex');
  else
    -- Canonical replay loop (same as before)
    for v_step in 1..v_max_step loop
      v_t := v_step * v_dt;

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

        v_parts := array_append(
          v_parts,
          (v_step::text) || ':' ||
          (n.node_id::text) || ':' ||
          (v_t::text) || ':' ||
          (jsonb_build_object(
            'position', jsonb_build_object('x',px,'y',py,'z',pz),
            'temperature_k', temp,
            'pressure_pa', press,
            'displacement', disp,
            'velocity', vel,
            'resonance_amplitude', res
          )::text)
        );
      end loop;
    end loop;

    v_all := coalesce(array_to_string(v_parts, '|'), '');
    v_readings_hash := encode(
      extensions.digest(convert_to(v_all, 'utf8'), 'sha256'),
      'hex'
    );
  end if;

  -- Envelope (mirrors engine_run_hash_sha256)
  v_payload :=
    v_header
    || '|cfg=' || v_cfg_text
    || '|nodes=' || v_nodes_hash
    || '|readings=' || v_readings_hash;

  return encode(
    extensions.digest(convert_to(v_payload, 'utf8'), 'sha256'),
    'hex'
  );
end;
$$;

commit;
