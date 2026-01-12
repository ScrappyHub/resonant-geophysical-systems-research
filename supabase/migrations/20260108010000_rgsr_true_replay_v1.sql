begin;

-- ============================================================
-- RGSR TRUE REPLAY (CANONICAL v1)
-- - Adds replay audit table
-- - Implements TRUE replay hash (no reads from stored readings other than max_step)
-- - Adds a replay runner that records audit metadata
-- - Extends attestation view with replay stats (safe additive columns)
-- ============================================================

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- 1) Replay audit table (append-only)
-- ------------------------------------------------------------
create table if not exists rgsr.engine_run_replay_runs (
  replay_run_id uuid primary key default gen_random_uuid(),
  run_id        uuid not null references rgsr.engine_runs(run_id) on delete cascade,
  actor_uid     uuid null,
  started_at    timestamptz not null default now(),
  ended_at      timestamptz null,
  replay_hash_sha256 text null,
  ok            boolean not null default false,
  error_text    text null,
  metadata      jsonb not null default '{}'::jsonb
);

comment on table rgsr.engine_run_replay_runs is
'Append-only replay audit log. Never mutates sealed runs/readings. Records replay hash and actor metadata.';

-- ------------------------------------------------------------
-- 2) TRUE replay hash function
--    Mirrors rgsr.step_engine_run_2d math *exactly* but does NOT write readings.
--    Only reads:
--      - engine_runs dt_sec/config_id
--      - engine_configs config seed/excitation
--      - engine_run_nodes positions
--      - engine_run_readings max(step_index)  (read-only)
-- ------------------------------------------------------------
create or replace function rgsr.replay_engine_run_hash_sha256(p_run_id uuid)
returns text
language plpgsql
stable
security definer
set search_path to 'rgsr', 'public'
as $function$
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
begin
  -- Basic existence + dt
  select dt_sec
    into v_dt
  from rgsr.engine_runs
  where run_id = p_run_id;

  if v_dt is null then
    raise exception 'RUN_NOT_FOUND' using errcode='22023';
  end if;

  -- Config (same join as step fn)
  select ec.config
    into v_cfg
  from rgsr.engine_runs r
  join rgsr.engine_configs ec
    on ec.config_id = r.config_id
  where r.run_id = p_run_id;

  v_cfg := coalesce(v_cfg, '{}'::jsonb);

  v_exc   := coalesce(v_cfg->'excitation', '{}'::jsonb);
  v_freq  := coalesce(nullif(v_exc->>'frequency_hz','')::numeric, 1000);
  v_amp   := coalesce(nullif(v_exc->>'amplitude','')::numeric, 0.25);
  v_phase := coalesce(nullif(v_exc->>'phase_offset_deg','')::numeric, 0);

  -- Determine how many steps were actually written (sealed reality)
  select coalesce(max(step_index), 0)
    into v_max_step
  from rgsr.engine_run_readings
  where run_id = p_run_id;

  if v_max_step <= 0 then
    -- No readings -> hash of empty string (matches engine_run_hash_sha256 behavior)
    return encode(
      extensions.digest(convert_to('', 'utf8'), 'sha256'),
      'hex'
    );
  end if;

  -- Require nodes present (replay cannot mutate anything)
  if not exists (
    select 1 from rgsr.engine_run_nodes where run_id = p_run_id
  ) then
    raise exception 'REPLAY_NODES_MISSING run_id=%', p_run_id using errcode='22023';
  end if;

  -- Canonical replay loop:
  -- same math as step_engine_run_2d
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

      -- Build EXACT readings payload shape used in step_engine_run_2d
      -- Note: jsonb normalizes key ordering, matching stored jsonb::text behavior.
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

  return encode(
    extensions.digest(convert_to(v_all, 'utf8'), 'sha256'),
    'hex'
  );
end;
$function$;

comment on function rgsr.replay_engine_run_hash_sha256(uuid) is
'TRUE replay hash. Mirrors step_engine_run_2d math without writing to sealed tables.';

-- ------------------------------------------------------------
-- 3) Replay runner: computes replay hash + records audit row
--    This does NOT touch engine_runs or engine_run_readings.
-- ------------------------------------------------------------
create or replace function rgsr.run_engine_run_replay(
  p_run_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'rgsr', 'public'
as $function$
declare
  v_replay_run_id uuid;
  v_hash text;
begin
  insert into rgsr.engine_run_replay_runs(run_id, actor_uid, started_at, ok, metadata)
  values (p_run_id, rgsr.actor_uid(), now(), false, coalesce(p_metadata,'{}'::jsonb))
  returning replay_run_id into v_replay_run_id;

  begin
    v_hash := rgsr.replay_engine_run_hash_sha256(p_run_id);

    update rgsr.engine_run_replay_runs
      set ended_at = now(),
          replay_hash_sha256 = v_hash,
          ok = true
    where replay_run_id = v_replay_run_id;

  exception when others then
    update rgsr.engine_run_replay_runs
      set ended_at = now(),
          ok = false,
          error_text = sqlerrm
    where replay_run_id = v_replay_run_id;
    raise;
  end;

  return v_replay_run_id;
end;
$function$;

comment on function rgsr.run_engine_run_replay(uuid, jsonb) is
'Runs TRUE replay and records an audit row. Safe post-seal: does not mutate engine_runs/readings.';

-- ------------------------------------------------------------
-- 4) Extend attestation view (additive columns at end)
-- ------------------------------------------------------------
create or replace view rgsr.v_engine_run_attestation as
select
  r.run_id,
  r.owner_uid,
  r.config_id,
  r.engine_kind,
  r.status,
  r.started_at,
  r.ended_at,
  r.tick_hz,
  r.dt_sec,
  r.max_steps,
  r.created_at,
  r.updated_at,
  r.seal_hash_sha256,
  r.replay_hash_sha256,
  r.hashes_match,
  coalesce(rr.readings_count, 0::bigint) as readings_count,
  rr.min_step_index,
  rr.max_step_index,
  rr.min_created_at as readings_first_at,
  rr.max_created_at as readings_last_at,

  -- Additive replay metadata
  coalesce(pr.replay_runs_count, 0::bigint) as replay_runs_count,
  pr.last_replay_at,
  pr.last_replay_ok,
  pr.last_replay_hash_sha256

from rgsr.engine_runs r
left join (
  select
    engine_run_readings.run_id,
    count(*) as readings_count,
    min(engine_run_readings.step_index) as min_step_index,
    max(engine_run_readings.step_index) as max_step_index,
    min(engine_run_readings.created_at) as min_created_at,
    max(engine_run_readings.created_at) as max_created_at
  from rgsr.engine_run_readings
  group by engine_run_readings.run_id
) rr on rr.run_id = r.run_id
left join (
  select
    e.run_id,
    count(*) as replay_runs_count,
    max(e.ended_at) as last_replay_at,
    (array_agg(e.ok order by e.ended_at desc nulls last, e.started_at desc))[1] as last_replay_ok,
    (array_agg(e.replay_hash_sha256 order by e.ended_at desc nulls last, e.started_at desc))[1] as last_replay_hash_sha256
  from rgsr.engine_run_replay_runs e
  group by e.run_id
) pr on pr.run_id = r.run_id;

commit;
