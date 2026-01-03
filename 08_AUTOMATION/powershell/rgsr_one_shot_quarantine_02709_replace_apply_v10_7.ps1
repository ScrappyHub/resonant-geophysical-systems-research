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
# 1) QUARANTINE failing 20260102002709_* (pending + failing)
# ------------------------------------------------------------
$bad = Join-Path $mgDir "20260102002709_rgsr_runs_and_measurements_v10_1_fix.sql"
if (Test-Path -LiteralPath $bad) {
  $qDir = Join-Path $mgDir "_quarantine"
  EnsureDir $qDir
  $dst = Join-Path $qDir (Split-Path -Leaf $bad)
  Move-Item -LiteralPath $bad -Destination $dst -Force
  Write-Host ("[OK] QUARANTINED: " + $bad + " -> " + $dst) -ForegroundColor Yellow
} else {
  Write-Host "[INFO] No 02709 file found to quarantine." -ForegroundColor Gray
}

# ------------------------------------------------------------
# 2) WRITE replacement 027091 repair migration (safe/idempotent)
# ------------------------------------------------------------
$NewPath = Join-Path $mgDir "202601020027091_rgsr_runs_and_measurements_v10_1_fix_SAFE_REPAIR.sql"
if (-not (Test-Path -LiteralPath $NewPath)) {

  $sqlLines = @(
'-- ============================================================',
'-- RGSR v10.1 FIX SAFE REPAIR (replaces quarantined 02709)',
'-- Goal: ensure lab_members invariants without constraint-name collisions.',
'-- - Ensures columns exist',
'-- - Ensures role check exists (by definition match)',
'-- - Ensures UNIQUE coverage of (lab_id,user_id) via unique index if needed',
'-- ============================================================',
'',
'begin;',
'',
'-- minimal safety: tables should already exist by v10, but never assume',
'create table if not exists rgsr.labs (lab_id uuid primary key default gen_random_uuid());',
'create table if not exists rgsr.lab_members (membership_id uuid primary key default gen_random_uuid(), lab_id uuid null, user_id uuid null);',
'',
'-- 1) normalize lab_members columns',
'do $do$',
'begin',
'  if not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''lab_members'' and column_name=''member_role'') then',
'    execute ''alter table rgsr.lab_members add column member_role text not null default ''''MEMBER'''''';',
'  end if;',
'  if not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''lab_members'' and column_name=''is_active'') then',
'    execute ''alter table rgsr.lab_members add column is_active boolean not null default true'';',
'  end if;',
'  if not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''lab_members'' and column_name=''created_at'') then',
'    execute ''alter table rgsr.lab_members add column created_at timestamptz not null default now()'';',
'  end if;',
'  if not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''lab_members'' and column_name=''updated_at'') then',
'    execute ''alter table rgsr.lab_members add column updated_at timestamptz not null default now()'';',
'  end if;',
'end',
'$do$;',
'',
'-- 2) role check constraint: add only if no equivalent check exists',
'do $do$',
'declare v_exists boolean;',
'begin',
'  select exists(',
'    select 1',
'    from pg_constraint c',
'    join pg_class t on t.oid = c.conrelid',
'    join pg_namespace n on n.oid = t.relnamespace',
'    where n.nspname = ''rgsr'' and t.relname = ''lab_members'' and c.contype = ''c''',
'      and pg_get_constraintdef(c.oid) like ''%member_role%OWNER%ADMIN%MEMBER%VIEWER%''',
'  ) into v_exists;',
'',
'  if not v_exists then',
'    begin',
'      execute ''alter table rgsr.lab_members add constraint lab_members_role_chk_v10repair check (member_role in (''''OWNER'''',''''ADMIN'''',''''MEMBER'''',''''VIEWER''''))'';',
'    exception when duplicate_object then null;',
'    end;',
'  end if;',
'end',
'$do$;',
'',
'-- 3) uniqueness: if any UNIQUE index/constraint covers both columns, do nothing; else create safe unique index',
'do $do$',
'declare v_has_unique boolean;',
'begin',
'  select exists(',
'    select 1',
'    from pg_index i',
'    join pg_class t on t.oid = i.indrelid',
'    join pg_namespace n on n.oid = t.relnamespace',
'    where n.nspname = ''rgsr'' and t.relname = ''lab_members''',
'      and i.indisunique = true',
'      and (',
'        select count(*)',
'        from unnest(i.indkey) k(attnum)',
'        join pg_attribute a on a.attrelid = t.oid and a.attnum = k.attnum',
'        where a.attname in (''lab_id'',''user_id'')',
'      ) = 2',
'  ) into v_has_unique;',
'',
'  if not v_has_unique then',
'    begin',
'      execute ''create unique index if not exists ux_lab_members_lab_user_v10repair on rgsr.lab_members(lab_id, user_id)'';',
'    exception when duplicate_object then null;',
'    end;',
'  end if;',
'end',
'$do$;',
'',
'create index if not exists ix_lab_members_lab on rgsr.lab_members(lab_id);',
'create index if not exists ix_lab_members_user on rgsr.lab_members(user_id);',
'',
'commit;',
'-- ============================================================',
'-- End SAFE REPAIR',
'-- ============================================================'
  )

  $sql = ($sqlLines -join "`r`n") + "`r`n"
  WriteUtf8NoBom $NewPath $sql
  Write-Host ("[OK] REPLACEMENT 027091 READY: " + $NewPath) -ForegroundColor Green
} else {
  Write-Host ("[INFO] Replacement 027091 already exists: " + $NewPath) -ForegroundColor Gray
}

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

Write-Host "✅ QUARANTINE(02709)+REPLACE(027091)+APPLY COMPLETE (v10.7)" -ForegroundColor Green