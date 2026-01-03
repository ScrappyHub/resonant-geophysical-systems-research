param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [switch]$LinkProject,
  [string]$ProjectRef = "",
  [switch]$ApplyRemote
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
  Write-Host ("[OK] WROTE " + $Path) -ForegroundColor DarkGreen
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

if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "RepoRoot not found: $RepoRoot" }
Set-Location $RepoRoot

$mgDir = Join-Path $RepoRoot "supabase\migrations"
EnsureDir $mgDir

Write-Host ("[INFO] RepoRoot=" + $RepoRoot) -ForegroundColor Gray
Write-Host ("[INFO] mgDir=" + $mgDir) -ForegroundColor Gray

$sb = (Get-Command supabase -ErrorAction SilentlyContinue)
if (-not $sb) { throw "supabase CLI not found in PATH." }

# ------------------------------------------------------------
# 1) QUARANTINE broken v10.8 migration (if present)
# ------------------------------------------------------------
$bad = Join-Path $mgDir "20260102013743_rgsr_v10_8_harden_verify.sql"
if (Test-Path -LiteralPath $bad) {
  $qDir = Join-Path $mgDir "_quarantine"
  EnsureDir $qDir
  $dst = Join-Path $qDir (Split-Path -Leaf $bad)
  Move-Item -LiteralPath $bad -Destination $dst -Force
  Write-Host ("[OK] QUARANTINED: " + $bad + " -> " + $dst) -ForegroundColor Yellow
} else {
  Write-Host "[INFO] No broken v10.8 file found to quarantine." -ForegroundColor Gray
}

# ------------------------------------------------------------
# 2) WRITE fixed replacement migration (v10.8.1)
# ------------------------------------------------------------
$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_v10_8_1_harden_verify_fixed.sql" -f $MigrationId)

$sqlLines = @(
'-- ============================================================',
'-- RGSR v10.8.1 HARDEN + VERIFY (FIXED) — NO LEAKAGE',
'-- - Safe grants (no invalid exception conditions)',
'-- - Removes ALL non-canonical policies on core tables',
'-- - Recreates canonical governed policies deterministically',
'-- - Enables + FORCES RLS on core tables',
'-- ============================================================',
'',
'begin;',
'',
'-- ------------------------------------------------------------',
'-- 0) Schema existence guard',
'-- ------------------------------------------------------------',
'do $do$',
'begin',
'  if to_regnamespace(''rgsr'') is null then',
'    -- If schema does not exist, do nothing (but do not fail).',
'    return;',
'  end if;',
'end',
'$do$;',
'',
'-- ------------------------------------------------------------',
'-- 1) Defensive grants (RLS is the gate; grants should be minimal)',
'-- ------------------------------------------------------------',
'do $do$',
'declare t record;',
'declare f record;',
'begin',
'  -- Schema usage (safe; schema exists here)',
'  execute ''revoke all on schema rgsr from public'';',
'  execute ''grant usage on schema rgsr to authenticated'';',
'  execute ''grant usage on schema rgsr to service_role'';',
'',
'  -- Tables in rgsr: revoke broad access; grant DML to authenticated + service_role (RLS still gates rows)',
'  for t in',
'    select table_schema, table_name',
'    from information_schema.tables',
'    where table_schema=''rgsr'' and table_type=''BASE TABLE''',
'  loop',
'    execute format(''revoke all on table %I.%I from public'', t.table_schema, t.table_name);',
'    execute format(''revoke all on table %I.%I from anon'', t.table_schema, t.table_name);',
'    execute format(''grant select, insert, update, delete on table %I.%I to authenticated'', t.table_schema, t.table_name);',
'    execute format(''grant select, insert, update, delete on table %I.%I to service_role'', t.table_schema, t.table_name);',
'  end loop;',
'',
'  -- Functions in rgsr: revoke execute from public; grant execute to authenticated + service_role',
'  for f in',
'    select n.nspname as schema_name, p.proname as fn_name, pg_get_function_identity_arguments(p.oid) as args',
'    from pg_proc p',
'    join pg_namespace n on n.oid = p.pronamespace',
'    where n.nspname = ''rgsr''',
'  loop',
'    execute format(''revoke all on function %I.%I(%s) from public'', f.schema_name, f.fn_name, f.args);',
'    execute format(''grant execute on function %I.%I(%s) to authenticated'', f.schema_name, f.fn_name, f.args);',
'    execute format(''grant execute on function %I.%I(%s) to service_role'', f.schema_name, f.fn_name, f.args);',
'  end loop;',
'end',
'$do$;',
'',
'-- ------------------------------------------------------------',
'-- 2) Ensure RLS is enabled + forced on core tables',
'-- ------------------------------------------------------------',
'do $do$',
'begin',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''labs'') then',
'    execute ''alter table rgsr.labs enable row level security'';',
'    execute ''alter table rgsr.labs force row level security'';',
'  end if;',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''lab_members'') then',
'    execute ''alter table rgsr.lab_members enable row level security'';',
'    execute ''alter table rgsr.lab_members force row level security'';',
'  end if;',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''runs'') then',
'    execute ''alter table rgsr.runs enable row level security'';',
'    execute ''alter table rgsr.runs force row level security'';',
'  end if;',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''run_measurements'') then',
'    execute ''alter table rgsr.run_measurements enable row level security'';',
'    execute ''alter table rgsr.run_measurements force row level security'';',
'  end if;',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''run_artifacts'') then',
'    execute ''alter table rgsr.run_artifacts enable row level security'';',
'    execute ''alter table rgsr.run_artifacts force row level security'';',
'  end if;',
'end',
'$do$;',
'',
'-- ------------------------------------------------------------',
'-- 3) POLICY QUARANTINE: drop ALL non-canonical policies on core tables',
'--    (PERMISSIVE union is dangerous; we keep only the canonical set)',
'-- ------------------------------------------------------------',
'do $do$',
'declare p record;',
'begin',
'  for p in',
'    select schemaname, tablename, policyname',
'    from pg_policies',
'    where schemaname=''rgsr''',
'      and tablename in (''labs'',''lab_members'',''runs'',''run_measurements'',''run_artifacts'')',
'      and policyname not in (',
'        ''labs_select'',''labs_write'',',
'        ''lm_select'',''lm_write'',',
'        ''runs_select'',''runs_write'',',
'        ''rm_select'',''rm_write'',',
'        ''ra_select'',''ra_write''',
'      )',
'  loop',
'    execute format(''drop policy if exists %I on %I.%I'', p.policyname, p.schemaname, p.tablename);',
'  end loop;',
'end',
'$do$;',
'',
'-- ------------------------------------------------------------',
'-- 4) Recreate canonical policies deterministically (drop+create)',
'-- ------------------------------------------------------------',
'-- labs',
'drop policy if exists labs_select on rgsr.labs;',
'drop policy if exists labs_write  on rgsr.labs;',
'create policy labs_select on rgsr.labs for select to authenticated',
'  using (',
'    (rgsr.can_read_lane(lane, lab_id))',
'    or exists (select 1 from rgsr.lab_members m where m.lab_id = labs.lab_id and m.user_id = rgsr.me() and m.is_active = true)',
'  );',
'create policy labs_write on rgsr.labs for all to authenticated',
'  using (rgsr.can_write())',
'  with check (rgsr.can_write());',
'',
'-- lab_members',
'drop policy if exists lm_select on rgsr.lab_members;',
'drop policy if exists lm_write  on rgsr.lab_members;',
'create policy lm_select on rgsr.lab_members for select to authenticated',
'  using (user_id = rgsr.me() or rgsr.can_write());',
'create policy lm_write on rgsr.lab_members for all to authenticated',
'  using (rgsr.can_write())',
'  with check (rgsr.can_write());',
'',
'-- runs',
'drop policy if exists runs_select on rgsr.runs;',
'drop policy if exists runs_write  on rgsr.runs;',
'create policy runs_select on rgsr.runs for select to authenticated',
'  using (rgsr.can_read_lane(lane, lab_id));',
'create policy runs_write on rgsr.runs for all to authenticated',
'  using (rgsr.can_write())',
'  with check (rgsr.can_write());',
'',
'-- run_measurements (inherits run visibility)',
'drop policy if exists rm_select on rgsr.run_measurements;',
'drop policy if exists rm_write  on rgsr.run_measurements;',
'create policy rm_select on rgsr.run_measurements for select to authenticated',
'  using (exists (select 1 from rgsr.runs r where r.run_id = run_measurements.run_id and rgsr.can_read_lane(r.lane, r.lab_id)));',
'create policy rm_write on rgsr.run_measurements for all to authenticated',
'  using (rgsr.can_write())',
'  with check (rgsr.can_write());',
'',
'-- run_artifacts (inherits run visibility)',
'drop policy if exists ra_select on rgsr.run_artifacts;',
'drop policy if exists ra_write  on rgsr.run_artifacts;',
'create policy ra_select on rgsr.run_artifacts for select to authenticated',
'  using (exists (select 1 from rgsr.runs r where r.run_id = run_artifacts.run_id and rgsr.can_read_lane(r.lane, r.lab_id)));',
'create policy ra_write on rgsr.run_artifacts for all to authenticated',
'  using (rgsr.can_write())',
'  with check (rgsr.can_write());',
'',
'commit;',
'-- ============================================================',
'-- End v10.8.1 harden+verify fixed',
'-- ============================================================'
)

$sql = ($sqlLines -join "`r`n") + "`r`n"
WriteUtf8NoBom $mgPath $sql
Write-Host ("[OK] NEW MIGRATION READY: " + $mgPath) -ForegroundColor Green

# ------------------------------------------------------------
# 3) Link + Push
# ------------------------------------------------------------
if ($LinkProject) {
  if (-not $ProjectRef) { throw "ProjectRef is required for link." }
  Invoke-Supabase -SbArgs @("link","--project-ref",$ProjectRef)
  Write-Host "[OK] supabase link complete" -ForegroundColor Green
}

if ($ApplyRemote) {
  Invoke-Supabase -SbArgs @("db","push") -PipeYes
  Write-Host "[OK] supabase db push complete" -ForegroundColor Green
}

Write-Host "✅ QUARANTINE+REPLACE+APPLY COMPLETE (v10.8.1)" -ForegroundColor Green