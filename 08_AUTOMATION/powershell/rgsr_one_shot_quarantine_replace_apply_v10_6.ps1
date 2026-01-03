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
# 1) QUARANTINE failing 017191 migration (pending + failing)
# ------------------------------------------------------------
$bad = Join-Path $mgDir "202601020017191_rgsr_v10_prelude_lab_members_patch_SAFE.sql"
if (Test-Path -LiteralPath $bad) {
  $qDir = Join-Path $mgDir "_quarantine"
  EnsureDir $qDir
  $dst = Join-Path $qDir (Split-Path -Leaf $bad)
  Move-Item -LiteralPath $bad -Destination $dst -Force
  Write-Host ("[OK] QUARANTINED: " + $bad + " -> " + $dst) -ForegroundColor Yellow
} else {
  Write-Host "[INFO] No 017191 file found to quarantine." -ForegroundColor Gray
}

# ------------------------------------------------------------
# 2) WRITE replacement prelude 017192 (sorts before 01720)
# ------------------------------------------------------------
$NewPath = Join-Path $mgDir "202601020017192_rgsr_v10_prelude_lab_members_patch_SAFE2.sql"
if (-not (Test-Path -LiteralPath $NewPath)) {

  $sqlLines = @(
'-- ============================================================',
'-- RGSR v10 PRELUDE SAFE2 (replaces quarantined 017191)',
'-- FIX: type-stable uniqueness detection (no integer[] @> smallint[])',
'-- ============================================================',
'',
'begin;',
'',
'create table if not exists rgsr.labs (lab_id uuid primary key default gen_random_uuid());',
'create table if not exists rgsr.lab_members (membership_id uuid primary key default gen_random_uuid(), lab_id uuid null, user_id uuid null);',
'',
'-- normalize expected columns',
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
'-- role check constraint: add only if no equivalent check exists',
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
'      execute ''alter table rgsr.lab_members add constraint lab_members_role_chk_v10safe2 check (member_role in (''''OWNER'''',''''ADMIN'''',''''MEMBER'''',''''VIEWER''''))'';',
'    exception when duplicate_object then null;',
'    end;',
'  end if;',
'end',
'$do$;',
'',
'-- uniqueness on (lab_id,user_id): detect any UNIQUE index that covers both columns via unnest(indkey)',
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
'      execute ''create unique index if not exists ux_lab_members_lab_user_v10safe2 on rgsr.lab_members(lab_id, user_id)'';',
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
'-- End PRELUDE SAFE2',
'-- ============================================================'
  )

  $sql = ($sqlLines -join "`r`n") + "`r`n"
  WriteUtf8NoBom $NewPath $sql
  Write-Host ("[OK] REPLACEMENT PRELUDE READY: " + $NewPath) -ForegroundColor Green

} else {
  Write-Host ("[INFO] Replacement prelude already exists: " + $NewPath) -ForegroundColor Gray
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

Write-Host "✅ QUARANTINE(017191)+REPLACE(017192)+APPLY COMPLETE (v10.6)" -ForegroundColor Green