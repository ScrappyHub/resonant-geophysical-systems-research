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

$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_v10_9_invariants_lane_locks.sql" -f $MigrationId)

$sqlLines = @(
'-- ============================================================',
'-- RGSR v10.9 — INVARIANTS + LANE LOCKS (NO LEAKAGE)',
'-- - Adds hard lane invariants for rgsr.runs',
'-- - Hardens rgsr.lab_members completeness + unique coverage',
'-- - Uses NOT VALID constraints first, then validates only if safe',
'-- ============================================================',
'',
'begin;',
'',
'-- Guard: schema must exist',
'do $do$',
'begin',
'  if to_regnamespace(''rgsr'') is null then',
'    return;',
'  end if;',
'end',
'$do$;',
'',
'-- ------------------------------------------------------------',
'-- 1) Ensure required columns exist (defensive; no assumptions)',
'-- ------------------------------------------------------------',
'do $do$',
'begin',
'  -- lab_members completeness columns should exist by v10.x, but never assume',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''lab_members'') then',
'    if not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''lab_members'' and column_name=''lab_id'') then',
'      execute ''alter table rgsr.lab_members add column lab_id uuid null'';',
'    end if;',
'    if not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''lab_members'' and column_name=''user_id'') then',
'      execute ''alter table rgsr.lab_members add column user_id uuid null'';',
'    end if;',
'  end if;',
'',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''runs'') then',
'    if not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''runs'' and column_name=''lane'') then',
'      execute ''alter table rgsr.runs add column lane text not null default ''''LAB'''''';',
'    end if;',
'    if not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''runs'' and column_name=''lab_id'') then',
'      execute ''alter table rgsr.runs add column lab_id uuid null'';',
'    end if;',
'  end if;',
'end',
'$do$;',
'',
'-- ------------------------------------------------------------',
'-- 2) RUNS lane invariants (NOT VALID first, then validate if safe)',
'--    Rules:',
'--      PUBLIC   => lab_id is null',
'--      LAB      => lab_id is not null',
'--      INTERNAL => lab_id is null',
'-- ------------------------------------------------------------',
'do $do$',
'declare v_bad bigint;',
'begin',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''runs'') then',
'',
'    -- Add constraint if missing (name is stable + unique)',
'    if not exists (',
'      select 1',
'      from pg_constraint c',
'      join pg_class t on t.oid = c.conrelid',
'      join pg_namespace n on n.oid = t.relnamespace',
'      where n.nspname=''rgsr'' and t.relname=''runs'' and c.conname=''runs_lane_labid_invariant_v10_9''',
'    ) then',
'      execute ''alter table rgsr.runs add constraint runs_lane_labid_invariant_v10_9',
'              check (',
'                (lane = ''''LAB'''' and lab_id is not null)',
'                or (lane in (''''PUBLIC'''',''''INTERNAL'''') and lab_id is null)',
'              ) not valid'';',
'    end if;',
'',
'    -- Validate only if there are zero violating rows',
'    execute ''select count(*) from rgsr.runs',
'             where not (',
'               (lane = ''''LAB'''' and lab_id is not null)',
'               or (lane in (''''PUBLIC'''',''''INTERNAL'''') and lab_id is null)',
'             )'' into v_bad;',
'    if v_bad = 0 then',
'      execute ''alter table rgsr.runs validate constraint runs_lane_labid_invariant_v10_9'';',
'    end if;',
'  end if;',
'end',
'$do$;',
'',
'-- ------------------------------------------------------------',
'-- 3) LAB_MEMBERS completeness (NOT VALID first, then validate if safe)',
'--    - lab_id not null',
'--    - user_id not null',
'-- ------------------------------------------------------------',
'do $do$',
'declare v_bad bigint;',
'begin',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''lab_members'') then',
'',
'    if not exists (',
'      select 1',
'      from pg_constraint c',
'      join pg_class t on t.oid = c.conrelid',
'      join pg_namespace n on n.oid = t.relnamespace',
'      where n.nspname=''rgsr'' and t.relname=''lab_members'' and c.conname=''lab_members_lab_id_notnull_v10_9''',
'    ) then',
'      execute ''alter table rgsr.lab_members add constraint lab_members_lab_id_notnull_v10_9',
'              check (lab_id is not null) not valid'';',
'    end if;',
'',
'    if not exists (',
'      select 1',
'      from pg_constraint c',
'      join pg_class t on t.oid = c.conrelid',
'      join pg_namespace n on n.oid = t.relnamespace',
'      where n.nspname=''rgsr'' and t.relname=''lab_members'' and c.conname=''lab_members_user_id_notnull_v10_9''',
'    ) then',
'      execute ''alter table rgsr.lab_members add constraint lab_members_user_id_notnull_v10_9',
'              check (user_id is not null) not valid'';',
'    end if;',
'',
'    execute ''select count(*) from rgsr.lab_members where lab_id is null'' into v_bad;',
'    if v_bad = 0 then execute ''alter table rgsr.lab_members validate constraint lab_members_lab_id_notnull_v10_9''; end if;',
'',
'    execute ''select count(*) from rgsr.lab_members where user_id is null'' into v_bad;',
'    if v_bad = 0 then execute ''alter table rgsr.lab_members validate constraint lab_members_user_id_notnull_v10_9''; end if;',
'  end if;',
'end',
'$do$;',
'',
'-- ------------------------------------------------------------',
'-- 4) LAB_MEMBERS uniqueness coverage for (lab_id,user_id)',
'--    - If any unique index/constraint covers both columns, do nothing',
'--    - Else create a safe unique index name (no collisions)',
'-- ------------------------------------------------------------',
'do $do$',
'declare v_has_unique boolean;',
'begin',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''lab_members'') then',
'    select exists(',
'      select 1',
'      from pg_index i',
'      join pg_class t on t.oid = i.indrelid',
'      join pg_namespace n on n.oid = t.relnamespace',
'      where n.nspname = ''rgsr'' and t.relname = ''lab_members''',
'        and i.indisunique = true',
'        and (',
'          select count(*)',
'          from unnest(i.indkey) k(attnum)',
'          join pg_attribute a on a.attrelid = t.oid and a.attnum = k.attnum',
'          where a.attname in (''lab_id'',''user_id'')',
'        ) = 2',
'    ) into v_has_unique;',
'',
'    if not v_has_unique then',
'      execute ''create unique index if not exists ux_lab_members_lab_user_v10_9 on rgsr.lab_members(lab_id, user_id)'';',
'    end if;',
'  end if;',
'end',
'$do$;',
'',
'-- ------------------------------------------------------------',
'-- 5) (Optional but recommended) tighten labs.lab_code later',
'--    We do NOT force NOT NULL here because legacy rows may exist.',
'--    v11 can backfill + enforce NOT NULL + UNIQUE constraint.',
'-- ------------------------------------------------------------',
'',
'commit;',
'-- ============================================================',
'-- End v10.9',
'-- ============================================================'
)

$sql = ($sqlLines -join "`r`n") + "`r`n"
WriteUtf8NoBom $mgPath $sql
Write-Host ("[OK] NEW MIGRATION READY: " + $mgPath) -ForegroundColor Green

if ($LinkProject) {
  if (-not $ProjectRef) { throw "ProjectRef is required for link." }
  Invoke-Supabase -SbArgs @("link","--project-ref",$ProjectRef)
  Write-Host "[OK] supabase link complete" -ForegroundColor Green
}

if ($ApplyRemote) {
  Invoke-Supabase -SbArgs @("db","push") -PipeYes
  Write-Host "[OK] supabase db push complete" -ForegroundColor Green
}

Write-Host "✅ v10.9 INVARIANTS + LANE LOCKS APPLIED" -ForegroundColor Green