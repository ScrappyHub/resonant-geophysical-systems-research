-- ============================================================
-- RGSR v13.2 â€” ENGINE RUN NODES + READINGS (REAL HOVER TOOLTIP DATA)
-- - Creates: engine_run_nodes, engine_run_readings
-- - RPCs: get_run_nodes, get_node_latest_reading
-- - Upgrades: step_engine_run_2d -> writes readings each step
-- - RLS: ENABLED + FORCED (no leaks)
-- ============================================================

begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 1) Run nodes (the nodes you hover)
-- ------------------------------------------------------------
create table if not exists rgsr.engine_run_nodes (
  run_id uuid not null references rgsr.engine_runs(run_id) on delete cascade,
  node_id text not null,
  position jsonb not null default '{}'::jsonb,     -- {x,y,z}
  measures text[] not null default '{}'::text[],   -- ['temperature','pressure',...]
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (run_id, node_id)
);

create index if not exists ix_engine_run_nodes_run on rgsr.engine_run_nodes(run_id);

-- ------------------------------------------------------------
-- 2) Run readings (time series)
-- ------------------------------------------------------------
create table if not exists rgsr.engine_run_readings (
  reading_id uuid primary key default gen_random_uuid(),
  run_id uuid not null references rgsr.engine_runs(run_id) on delete cascade,
  node_id text not null,
  step_index int not null,
  t_sim_sec numeric not null,
  readings jsonb not null default '{}'::jsonb,     -- canonical payload for tooltip
  created_at timestamptz not null default now()
);

create index if not exists ix_engine_run_readings_run_step on rgsr.engine_run_readings(run_id, step_index desc);
create index if not exists ix_engine_run_readings_run_node_step on rgsr.engine_run_readings(run_id, node_id, step_index desc);

-- ------------------------------------------------------------
-- 3) RLS + FORCE
-- ------------------------------------------------------------
alter table rgsr.engine_run_nodes enable row level security;
alter table rgsr.engine_run_nodes force row level security;

alter table rgsr.engine_run_readings enable row level security;
alter table rgsr.engine_run_readings force row level security;

-- Drop old policies (avoid union leakage)
do $do$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname='rgsr'
      and tablename in ('engine_run_nodes','engine_run_readings')
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end
$do$;

-- SELECT: owner only (via engine_runs.owner_uid)
create policy engine_run_nodes_read_own on rgsr.engine_run_nodes
for select to authenticated
using (
  exists (
    select 1 from rgsr.engine_runs r
    where r.run_id = engine_run_nodes.run_id
      and r.owner_uid = rgsr.actor_uid()
  )
);

create policy engine_run_readings_read_own on rgsr.engine_run_readings
for select to authenticated
using (
  exists (
    select 1 from rgsr.engine_runs r
    where r.run_id = engine_run_readings.run_id
      and r.owner_uid = rgsr.actor_uid()
  )
);

-- Admin full control (service/admin flows)
create policy engine_run_nodes_admin on rgsr.engine_run_nodes
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

create policy engine_run_readings_admin on rgsr.engine_run_readings
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- ------------------------------------------------------------
-- 4) RPC: list nodes for a run (UI hover uses this)
-- ------------------------------------------------------------
create or replace function rgsr.get_run_nodes(p_run_id uuid)
returns jsonb
language sql
stable
as $fn$
  select jsonb_build_object(
    'run_id', p_run_id,
    'nodes', coalesce(jsonb_agg(
      jsonb_build_object(
        'node_id', n.node_id,
        'position', n.position,
        'measures', n.measures,
        'metadata', n.metadata
      )
      order by n.node_id
    ), '[]'::jsonb)
  )
  from rgsr.engine_run_nodes n
  where n.run_id = p_run_id;
$fn$;

-- ------------------------------------------------------------
-- 5) RPC: latest reading for a node (this powers tooltips)
-- ------------------------------------------------------------
create or replace function rgsr.get_node_latest_reading(p_run_id uuid, p_node_id text)
returns jsonb
language sql
stable
as $fn$
  select coalesce((
    select jsonb_build_object(
      'run_id', r.run_id,
      'node_id', rr.node_id,
      'step_index', rr.step_index,
      't_sim_sec', rr.t_sim_sec,
      'readings', rr.readings,
      'created_at', rr.created_at
    )
    from rgsr.engine_run_readings rr
    join rgsr.engine_runs r on r.run_id = rr.run_id
    where rr.run_id = p_run_id
      and rr.node_id = p_node_id
    order by rr.step_index desc
    limit 1
  ), jsonb_build_object('run_id', p_run_id, 'node_id', p_node_id, 'readings', jsonb_build_object()));
$fn$;

-- ------------------------------------------------------------
-- 6) Helper: seed run nodes from engine_config.nodes (one-time per run)
-- ------------------------------------------------------------
create or replace function rgsr.seed_run_nodes_from_config(p_run_id uuid)
returns jsonb
language plpgsql
security definer
as $fn$
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

  select ec.config into v_cfg
  from rgsr.engine_runs r
  join rgsr.engine_configs ec on ec.config_id = r.engine_config_id
  where r.run_id = p_run_id;

  v_nodes := coalesce(v_cfg->'nodes','[]'::jsonb);
  if jsonb_typeof(v_nodes) <> 'array' then
    raise exception 'ENGINE_CONFIG_INVALID_NODES' using errcode='22023';
  end if;

  -- idempotent: only insert nodes missing
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
$fn$;

-- ------------------------------------------------------------
-- 7) Upgrade step_engine_run_2d: deterministic â€œreal reading payloadsâ€
--    NOTE: physics here is minimal but deterministic + audit-friendly.
--    You will later replace the core field solver without changing the schema.
-- ------------------------------------------------------------
create or replace function rgsr.step_engine_run_2d(p_run_id uuid, p_steps integer default 1)
returns jsonb
language plpgsql
security definer
as $fn$
declare
  v_owner uuid;
  v_dt numeric;
  v_step int;
  v_i int;
  v_cfg jsonb;
  v_exc jsonb;
  v_freq numeric;
  v_amp numeric;
  v_phase numeric;
  v_seed bigint;
  v_t numeric;

  n record;
  px numeric; py numeric; pz numeric;
  temp numeric; press numeric; disp numeric; vel numeric; res numeric;

  v_written int := 0;
begin
  if p_steps is null or p_steps < 1 or p_steps > 2000 then
    raise exception 'STEPS_OUT_OF_RANGE (1..2000)' using errcode='22023';
  end if;

  select owner_uid, dt_sec, coalesce((stats->>'step_index')::int,0)
    into v_owner, v_dt, v_step
  from rgsr.engine_runs
  where run_id = p_run_id;

  if v_owner is null then
    raise exception 'RUN_NOT_FOUND' using errcode='22023';
  end if;

  if v_owner <> rgsr.actor_uid() and not rgsr.can_write() then
    raise exception 'FORBIDDEN' using errcode='28000';
  end if;

  -- Ensure nodes seeded
  perform rgsr.seed_run_nodes_from_config(p_run_id);

  -- Load config (deterministic controls)
  select ec.config, coalesce(ec.seed,0)
    into v_cfg, v_seed
  from rgsr.engine_runs r
  join rgsr.engine_configs ec on ec.config_id = r.engine_config_id
  where r.run_id = p_run_id;

  v_exc := coalesce(v_cfg->'excitation','{}'::jsonb);
  v_freq := coalesce(nullif(v_exc->>'frequency_hz','')::numeric, 1000);
  v_amp  := coalesce(nullif(v_exc->>'amplitude','')::numeric, 0.25);
  v_phase:= coalesce(nullif(v_exc->>'phase_offset_deg','')::numeric, 0);

  for v_i in 1..p_steps loop
    v_step := v_step + 1;
    v_t := v_step * v_dt;

    -- For each node, compute deterministic coupled readings
    for n in
      select node_id, position
      from rgsr.engine_run_nodes
      where run_id = p_run_id
    loop
      px := coalesce(nullif(n.position->>'x','')::numeric, 0);
      py := coalesce(nullif(n.position->>'y','')::numeric, 0);
      pz := coalesce(nullif(n.position->>'z','')::numeric, 0);

      -- Minimal deterministic â€œfield proxyâ€ (replace with real solver later)
      -- Acoustic displacement proxy
      disp := v_amp * sin(2*pi()*v_freq*v_t + (v_phase*pi()/180) + (px+py+pz)*0.05);

      -- Velocity proxy
      vel  := (2*pi()*v_freq) * v_amp * cos(2*pi()*v_freq*v_t + (v_phase*pi()/180) + (px+py+pz)*0.05);

      -- Pressure proxy (scaled displacement)
      press := 101325 + (disp * 2500);

      -- Thermal proxy (slow drift + coupling to acoustic energy)
      temp := 293.15 + (abs(disp) * 12) + (sin((px*0.01)+(v_t*0.2)) * 1.5);

      -- Resonance amplitude proxy (coupled)
      res := abs(disp) * 0.8 + abs(vel) * 0.00001;

      insert into rgsr.engine_run_readings(run_id, node_id, step_index, t_sim_sec, readings, created_at)
      values (
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
    end loop;

  end loop;

  update rgsr.engine_runs
    set stats = coalesce(stats,'{}'::jsonb) || jsonb_build_object('step_index', v_step),
        updated_at = now()
  where run_id = p_run_id;

  return jsonb_build_object('ok', true, 'run_id', p_run_id, 'steps', p_steps, 'step_index', v_step, 'readings_written', v_written);
end
$fn$;

commit;
