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
# PRELUDE MIGRATION: MUST SORT BEFORE 20260102001720_...
# ------------------------------------------------------------
$PreludeId = "20260102001719"
$PreludeName = "{0}_rgsr_v10_prelude_lab_members_patch.sql" -f $PreludeId
$PreludePath = Join-Path $mgDir $PreludeName

if (-not (Test-Path -LiteralPath $PreludePath)) {

  $sqlLines = @(
'-- ============================================================',
'-- RGSR v10 PRELUDE (MUST RUN BEFORE 20260102001720)',
'-- Ensures rgsr.labs + rgsr.lab_members columns exist so v10',
'-- functions (has_lab_access) compile without column errors.',
'-- NO LEAKAGE: this is structural only (no policies here).',
'-- ============================================================',
'',
'begin;',
'',
'create table if not exists rgsr.labs (',
'  lab_id uuid primary key default gen_random_uuid(),',
'  lane text not null default ''LAB'',',
'  lab_code text not null unique,',
'  display_name text not null,',
'  description text null,',
'  created_by uuid references auth.users(id) on delete set null,',
'  created_at timestamptz not null default now(),',
'  updated_at timestamptz not null default now(),',
'  constraint labs_lane_chk check (lane in (''LAB'',''INTERNAL''))',
');',
'create index if not exists ix_labs_code on rgsr.labs(lab_code);',
'',
'create table if not exists rgsr.lab_members (',
'  membership_id uuid primary key default gen_random_uuid(),',
'  lab_id uuid not null references rgsr.labs(lab_id) on delete cascade,',
'  user_id uuid not null references auth.users(id) on delete cascade,',
'  member_role text not null default ''MEMBER'',',
'  is_active boolean not null default true,',
'  created_at timestamptz not null default now(),',
'  updated_at timestamptz not null default now(),',
'  constraint lab_members_role_chk check (member_role in (''OWNER'',''ADMIN'',''MEMBER'',''VIEWER'')),',
'  constraint lab_members_unique unique (lab_id, user_id)',
');',
'create index if not exists ix_lab_members_lab on rgsr.lab_members(lab_id);',
'create index if not exists ix_lab_members_user on rgsr.lab_members(user_id);',
'',
'-- Normalize older lab_members if it existed without these columns/constraints',
'do $do$',
'begin',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''lab_members'')',
'     and not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''lab_members'' and column_name=''member_role'') then',
'    execute ''alter table rgsr.lab_members add column member_role text not null default ''''MEMBER'''''';',
'  end if;',
'',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''lab_members'')',
'     and not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''lab_members'' and column_name=''is_active'') then',
'    execute ''alter table rgsr.lab_members add column is_active boolean not null default true'';',
'  end if;',
'',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''lab_members'')',
'     and not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''lab_members'' and column_name=''created_at'') then',
'    execute ''alter table rgsr.lab_members add column created_at timestamptz not null default now()'';',
'  end if;',
'  if exists (select 1 from information_schema.tables where table_schema=''rgsr'' and table_name=''lab_members'')',
'     and not exists (select 1 from information_schema.columns where table_schema=''rgsr'' and table_name=''lab_members'' and column_name=''updated_at'') then',
'    execute ''alter table rgsr.lab_members add column updated_at timestamptz not null default now()'';',
'  end if;',
'',
'  begin',
'    execute ''alter table rgsr.lab_members add constraint lab_members_unique unique (lab_id, user_id)'';',
'  exception when duplicate_object then null;',
'  end;',
'',
'  begin',
'    execute ''alter table rgsr.lab_members add constraint lab_members_role_chk check (member_role in (''''OWNER'''',''''ADMIN'''',''''MEMBER'''',''''VIEWER''''))'';',
'  exception when duplicate_object then null;',
'  end;',
'end',
'$do$;',
'',
'commit;',
'-- ============================================================',
'-- End prelude',
'-- ============================================================'
  )

  $sql = ($sqlLines -join "`r`n") + "`r`n"
  WriteUtf8NoBom $PreludePath $sql
  Write-Host ("[OK] PRELUDE MIGRATION READY: " + $PreludePath) -ForegroundColor Green

} else {
  Write-Host ("[INFO] Prelude already exists: " + $PreludePath) -ForegroundColor Gray
}

# ------------------------------------------------------------
# Link + Push
# ------------------------------------------------------------
if ($LinkProject) {
  if (-not $ProjectRef) { throw "ProjectRef is required for link." }
  Invoke-Supabase -SbArgs @("link","--project-ref",$ProjectRef)
  Write-Host "[OK] supabase link complete" -ForegroundColor Green
}

if ($ApplyRemote) {
  # supabase db push may still prompt; piping y is the most reliable no-prompt behavior.
  Invoke-Supabase -SbArgs @("db","push") -PipeYes
  Write-Host "[OK] supabase db push complete" -ForegroundColor Green
}

Write-Host "✅ PRELUDE+APPLY COMPLETE (v10.3)" -ForegroundColor Green