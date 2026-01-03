param(
  [Parameter(Mandatory=$false)][string]$ProjectRef = "zqhkyovksldzueqsznmd",
  [switch]$LinkProject = $true,
  [switch]$ApplyRemote = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
function WriteUtf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir) { EnsureDir $dir }
  [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
  Write-Host ("[OK] WROTE " + $Path) -ForegroundColor Green
}
function Invoke-Supabase([string[]]$SbArgs, [switch]$PipeYes) {
  if (-not $SbArgs -or $SbArgs.Count -eq 0) { throw "Invoke-Supabase called with empty args" }
  $argStr = ($SbArgs -join " ")
  if ($PipeYes) {
    cmd /c ("echo y| supabase " + $argStr) | Out-Host
    $code = $LASTEXITCODE
  } else {
    & supabase @SbArgs
    $code = $LASTEXITCODE
  }
  if ($code -ne 0) { throw ("supabase " + $argStr + " failed (exit=" + $code + ")") }
}

$RepoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $RepoRoot) { throw "Not in a git repo." }
Set-Location $RepoRoot

$mgDir = Join-Path $RepoRoot "supabase\migrations"
EnsureDir $mgDir

Write-Host ("[INFO] RepoRoot=" + $RepoRoot) -ForegroundColor Gray
Write-Host ("[INFO] mgDir=" + $mgDir) -ForegroundColor Gray

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) { throw "supabase CLI not found in PATH." }

$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_v13_1_engine_runs_2d_loop_hover_entitlements.sql" -f $MigrationId)

$sql = @'
-- ============================================================
-- RGSR v13.1 — ENGINE RUNS + CANONICAL 2D LOOP + NODE READINGS
-- + Hover tooltip RPC (real readings) + Entitlements gates
-- NO PII. RLS FORCED.
-- ============================================================

begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 0) Helpers: actor + entitlement gates (Workbench-only controls)
-- ------------------------------------------------------------

create or replace function rgsr.has_active_entitlement(p_key text)
returns boolean
language sql
stable
as $fn$
  select exists (
    select 1
    from rgsr.entitlements e
    where e.owner_uid = rgsr.actor_uid()
      and e.entitlement_key = p_key
      and e.active = true
      and (e.ends_at is null or e.ends_at > now())
  );
$fn$;

-- Workbench gate: you can tune keys later, but keep one canonical switch now
create or replace function rgsr.workbench_enabled()
returns boolean
language sql
stable
as $fn$
  select rgsr.has_active_entitlement('WORKBENCH');
$fn$;

-- ------------------------------------------------------------
-- 1) Engine configs table (idempotent harden)
-- ------------------------------------------------------------

create table if not exists rgsr.engine_configs (
  engine_config_id uuid primary key default gen_random_uuid(),
  owner_uid uuid not null references auth.users(id) on delete restrict,

  config_kind text not null,          -- 'DEMO_2D' | 'WORKBENCH_2D' | 'WORKBENCH_3D'
  schema_version int not null default 1,
  seed bigint not null default 1,

  title text not null default '',
  config jsonb not null default '{}'::jsonb,

  is_public boolean not null default false, -- website demo configs can be public if you choose
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint engine_configs_kind_chk check (config_kind in ('DEMO_2D','WORKBENCH_2D','WORKBENCH_3D')),
  constraint engine_configs_title_len check (length(title) <= 140)
);

create index if not exists ix_engine_configs_owner on rgsr.engine_configs(owner_uid, created_at desc);
create index if not exists ix_engine_configs_public on rgsr.engine_configs(is_public) where is_public=true;

-- attach validation trigger (safe create)
do $do$
begin
  if not exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='rgsr' and c.relname='engine_configs' and t.tgname='tg_engine_configs_validate'
  ) then
    create trigger tg_engine_configs_validate
    before insert or update on rgsr.engine_configs
    for each row execute function rgsr.tg_engine_configs_validate();
  end if;
end
$do$;

-- ------------------------------------------------------------
-- 2) Engine runs (canonical simulation loop scaffolding)
-- ------------------------------------------------------------

create table if not exists rgsr.engine_runs (
  run_id uuid primary key default gen_random_uuid(),
  owner_uid uuid not null references auth.users(id) on delete restrict,
  engine_config_id uuid not null references rgsr.engine_configs(engine_config_id) on delete restrict,

  engine_kind text not null default '2D',      -- '2D' | '3D' (future)
  status text not null default 'created',      -- created/running/paused/completed/failed
  started_at timestamptz null,
  ended_at timestamptz null,

  -- deterministic sim controls
  tick_hz numeric not null default 60,
  dt_sec numeric not null default 0.0166667,
  max_steps int not null default 6000,

  -- canonical run state
  state jsonb not null default '{}'::jsonb,
  stats jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint engine_runs_kind_chk check (engine_kind in ('2D','3D')),
  constraint engine_runs_status_chk check (status in ('created','running','paused','completed','failed')),
  constraint engine_runs_dt_chk check (dt_sec > 0 and dt_sec <= 1),
  constraint engine_runs_tick_chk check (tick_hz >= 1 and tick_hz <= 240)
);

create index if not exists ix_engine_runs_owner_time on rgsr.engine_runs(owner_uid, created_at desc);
create index if not exists ix_engine_runs_cfg on rgsr.engine_runs(engine_config_id);

-- ------------------------------------------------------------
-- 3) Per-step store (optional but useful for audits)
-- ------------------------------------------------------------

create table if not exists rgsr.engine_run_steps (
  step_id uuid primary key default gen_random_uuid(),
  run_id uuid not null references rgsr.engine_runs(run_id) on delete cascade,
  step_no int not null,
  t_sec numeric not null,
  -- minimal canonical fields (add later)
  fields jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint engine_run_steps_unique unique (run_id, step_no)
);

create index if not exists ix_engine_run_steps_run_step on rgsr.engine_run_steps(run_id, step_no);

-- ------------------------------------------------------------
-- 4) Node readings (THIS powers hover tooltips)
-- ------------------------------------------------------------

create table if not exists rgsr.engine_node_readings (
  reading_id uuid primary key default gen_random_uuid(),
  run_id uuid not null references rgsr.engine_runs(run_id) on delete cascade,
  node_id text not null,                     -- stable id from config nodes[*].node_id
  step_no int not null,
  t_sec numeric not null,

  -- canonical physical parameters (extend freely later)
  pos jsonb not null default '{}'::jsonb,    -- {x,y,z}
  temperature_c numeric null,
  pressure_pa numeric null,
  displacement_m numeric null,
  velocity_mps numeric null,
  resonance_amp numeric null,

  extra jsonb not null default '{}'::jsonb,  -- domain-specific overlays, wave phase, etc.
  created_at timestamptz not null default now(),

  constraint engine_node_readings_node_len check (length(node_id) <= 80)
);

create index if not exists ix_engine_node_readings_run_node_time on rgsr.engine_node_readings(run_id, node_id, step_no desc);

-- ------------------------------------------------------------
-- 5) Canonical RPCs
-- ------------------------------------------------------------

-- A) Create a run from an engine_config (DEMO_2D allowed; WORKBENCH requires entitlement)
create or replace function rgsr.create_engine_run(p_engine_config_id uuid)
returns uuid
language plpgsql
security invoker
as $fn$
declare
  v_uid uuid;
  v_kind text;
  v_run uuid;
begin
  v_uid := rgsr.actor_uid();
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode='28000'; end if;

  select ec.config_kind into v_kind
  from rgsr.engine_configs ec
  where ec.engine_config_id = p_engine_config_id
    and (ec.owner_uid = v_uid or ec.is_public = true);

  if v_kind is null then raise exception 'CONFIG_NOT_FOUND' using errcode='22023'; end if;

  if v_kind <> 'DEMO_2D' and not rgsr.workbench_enabled() then
    raise exception 'WORKBENCH_REQUIRED' using errcode='28000';
  end if;

  insert into rgsr.engine_runs(owner_uid, engine_config_id, engine_kind, status, started_at, state)
  values (v_uid, p_engine_config_id, '2D', 'created', null, '{}'::jsonb)
  returning run_id into v_run;

  return v_run;
end
$fn$;

-- B) Single canonical 2D step (placeholder math but REAL plumbing)
--    This is the *one* loop we wire the UI to. We will replace the physics later without changing API shape.
create or replace function rgsr.step_engine_run_2d(p_run_id uuid, p_steps int default 1)
returns jsonb
language plpgsql
security invoker
as $fn$
declare
  v_uid uuid;
  v_run rgsr.engine_runs%rowtype;
  v_cfg rgsr.engine_configs%rowtype;

  v_step int;
  v_base_step int;
  v_t numeric;
  v_dt numeric;

  v_nodes jsonb;
  n jsonb;
  v_node_id text;
  v_pos jsonb;

  v_freq numeric;
  v_amp numeric;
  v_phase numeric;

  v_temp numeric;
  v_press numeric;
  v_disp numeric;
  v_vel numeric;
  v_res numeric;

  v_written int := 0;
begin
  v_uid := rgsr.actor_uid();
  if v_uid is null then raise exception 'AUTH_REQUIRED' using errcode='28000'; end if;

  select * into v_run
  from rgsr.engine_runs
  where run_id = p_run_id and owner_uid = v_uid;

  if not found then raise exception 'RUN_NOT_FOUND' using errcode='22023'; end if;

  select * into v_cfg
  from rgsr.engine_configs
  where engine_config_id = v_run.engine_config_id;

  if not found then raise exception 'CONFIG_NOT_FOUND' using errcode='22023'; end if;

  if v_cfg.config_kind <> 'DEMO_2D' and not rgsr.workbench_enabled() then
    raise exception 'WORKBENCH_REQUIRED' using errcode='28000';
  end if;

  v_dt := v_run.dt_sec;

  -- pull nodes + excitation from config (validated already)
  v_nodes := v_cfg.config->'nodes';

  v_freq  := coalesce(nullif((v_cfg.config #>> '{excitation,frequency_hz}'), '')::numeric, 1000);
  v_amp   := coalesce(nullif((v_cfg.config #>> '{excitation,amplitude}'), '')::numeric, 0.5);
  v_phase := coalesce(nullif((v_cfg.config #>> '{excitation,phase_offset_deg}'), '')::numeric, 0);

  -- determine starting step based on existing steps
  select coalesce(max(step_no), -1) + 1 into v_base_step
  from rgsr.engine_run_steps
  where run_id = p_run_id;

  for v_step in 0..greatest(p_steps,1)-1 loop
    v_t := (v_base_step + v_step) * v_dt;

    -- write a step record (audit)
    insert into rgsr.engine_run_steps(run_id, step_no, t_sec, fields)
    values (p_run_id, v_base_step + v_step, v_t, jsonb_build_object('frequency_hz', v_freq, 'amplitude', v_amp))
    on conflict (run_id, step_no) do nothing;

    -- for each node, write a reading (REAL values, even if first-pass physics is simple)
    for n in select value from jsonb_array_elements(v_nodes) loop
      v_node_id := coalesce(n->>'node_id','');
      v_pos := coalesce(n->'position','{}'::jsonb);

      -- first-pass “provable” deterministic fields (replace later with real coupled solvers)
      -- sinusoid displacement + derived velocity + resonance amplitude proxy
      v_disp := v_amp * sin(2*pi()*v_freq*v_t + radians(v_phase));
      v_vel  := (2*pi()*v_freq) * v_amp * cos(2*pi()*v_freq*v_t + radians(v_phase));
      v_res  := abs(v_disp);

      -- simple thermal/pressure placeholders tied to displacement (so UI isn’t fake; it’s consistent & testable)
      v_temp := 20 + (5 * v_res);          -- °C
      v_press := 101325 + (200 * v_disp);  -- Pa

      insert into rgsr.engine_node_readings(
        run_id, node_id, step_no, t_sec,
        pos, temperature_c, pressure_pa, displacement_m, velocity_mps, resonance_amp, extra
      ) values (
        p_run_id, v_node_id, v_base_step + v_step, v_t,
        v_pos, v_temp, v_press, v_disp, v_vel, v_res,
        jsonb_build_object('phase_deg', v_phase, 'freq_hz', v_freq, 'amp', v_amp)
      );

      v_written := v_written + 1;
    end loop;
  end loop;

  update rgsr.engine_runs
    set status = 'running',
        started_at = coalesce(started_at, now()),
        updated_at = now()
  where run_id = p_run_id;

  return jsonb_build_object('ok', true, 'run_id', p_run_id, 'steps', p_steps, 'node_rows_written', v_written);
end
$fn$;

-- C) Hover tooltip RPC: latest readings for node ids (WHAT UI CALLS ON HOVER)
create or replace function rgsr.get_latest_node_readings(p_run_id uuid, p_node_ids text[] default '{}'::text[])
returns jsonb
language sql
stable
as $fn$
  with latest as (
    select distinct on (r.node_id)
      r.node_id, r.step_no, r.t_sec,
      r.pos, r.temperature_c, r.pressure_pa, r.displacement_m, r.velocity_mps, r.resonance_amp, r.extra,
      r.created_at
    from rgsr.engine_node_readings r
    join rgsr.engine_runs er on er.run_id=r.run_id
    where r.run_id = p_run_id
      and er.owner_uid = rgsr.actor_uid()
      and (cardinality(p_node_ids)=0 or r.node_id = any(p_node_ids))
    order by r.node_id, r.step_no desc
  )
  select jsonb_build_object(
    'ok', true,
    'run_id', p_run_id,
    'readings', coalesce(jsonb_agg(to_jsonb(latest) order by latest.node_id), '[]'::jsonb)
  )
  from latest;
$fn$;

-- ------------------------------------------------------------
-- 6) RLS ENABLE + FORCE
-- ------------------------------------------------------------

alter table rgsr.engine_configs enable row level security;
alter table rgsr.engine_runs enable row level security;
alter table rgsr.engine_run_steps enable row level security;
alter table rgsr.engine_node_readings enable row level security;

alter table rgsr.engine_configs force row level security;
alter table rgsr.engine_runs force row level security;
alter table rgsr.engine_run_steps force row level security;
alter table rgsr.engine_node_readings force row level security;

-- Drop non-canonical policies
do $do$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname='rgsr'
      and tablename in ('engine_configs','engine_runs','engine_run_steps','engine_node_readings')
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end
$do$;

-- ------------------------------------------------------------
-- 7) Canonical policies
-- ------------------------------------------------------------

-- engine_configs
create policy engine_configs_read_own on rgsr.engine_configs
for select to authenticated
using (owner_uid = rgsr.actor_uid() or is_public = true);

create policy engine_configs_write_own on rgsr.engine_configs
for insert, update, delete to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

create policy engine_configs_admin on rgsr.engine_configs
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- engine_runs
create policy engine_runs_read_own on rgsr.engine_runs
for select to authenticated
using (owner_uid = rgsr.actor_uid());

create policy engine_runs_write_own on rgsr.engine_runs
for insert, update, delete to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

create policy engine_runs_admin on rgsr.engine_runs
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- steps/readings follow run ownership
create policy engine_steps_read_own on rgsr.engine_run_steps
for select to authenticated
using (exists (select 1 from rgsr.engine_runs er where er.run_id=engine_run_steps.run_id and er.owner_uid=rgsr.actor_uid()));

create policy engine_steps_write_own on rgsr.engine_run_steps
for insert, update, delete to authenticated
using (exists (select 1 from rgsr.engine_runs er where er.run_id=engine_run_steps.run_id and er.owner_uid=rgsr.actor_uid()))
with check (exists (select 1 from rgsr.engine_runs er where er.run_id=engine_run_steps.run_id and er.owner_uid=rgsr.actor_uid()));

create policy engine_readings_read_own on rgsr.engine_node_readings
for select to authenticated
using (exists (select 1 from rgsr.engine_runs er where er.run_id=engine_node_readings.run_id and er.owner_uid=rgsr.actor_uid()));

create policy engine_readings_write_own on rgsr.engine_node_readings
for insert, update, delete to authenticated
using (exists (select 1 from rgsr.engine_runs er where er.run_id=engine_node_readings.run_id and er.owner_uid=rgsr.actor_uid()))
with check (exists (select 1 from rgsr.engine_runs er where er.run_id=engine_node_readings.run_id and er.owner_uid=rgsr.actor_uid()));

create policy engine_steps_admin on rgsr.engine_run_steps
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

create policy engine_readings_admin on rgsr.engine_node_readings
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

commit;
'@

WriteUtf8NoBom $mgPath ($sql + "`r`n")
Write-Host ("[OK] NEW MIGRATION READY: " + $mgPath) -ForegroundColor Green

if ($LinkProject) {
  Invoke-Supabase -SbArgs @("link","--project-ref",$ProjectRef)
  Write-Host "[OK] supabase link complete" -ForegroundColor Green
}

if ($ApplyRemote) {
  Invoke-Supabase -SbArgs @("db","push") -PipeYes
  Write-Host "[OK] supabase db push complete" -ForegroundColor Green
}

Write-Host "✅ v13.1 ENGINE RUNS + 2D LOOP + NODE READINGS + HOVER RPC + ENTITLEMENT GATES LOCKED-IN" -ForegroundColor Green
