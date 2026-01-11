<# 
  tools/local/post_reset_lock_auth.ps1
  Canonical: Post-reset auth schema lockdown for Supabase local.
  Enforces: anon/authenticated/public MUST NOT have USAGE on schema auth.
#>

[CmdletBinding()]
param(
  [string]$ContainerName = "",
  [string]$DbName = "postgres",
  [string]$DbUser = "supabase_admin",
  [Parameter(Mandatory=$true)]
  [string]$DbPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DbContainerName {
  param([string]$Name)
  if ($Name -and $Name.Trim().Length -gt 0) { return $Name.Trim() }

  $auto = (docker ps --format "{{.Names}}" | Select-String -Pattern "^supabase_db_" | Select-Object -First 1)
  if (-not $auto) { throw "Could not find a running container matching '^supabase_db_'. Is `supabase start` running?" }
  return $auto.ToString().Trim()
}

function Wait-DbHealthy {
  param([string]$Name)
  Write-Host "Waiting for DB container to be healthy: $Name"
  while ($true) {
    $h = docker inspect -f "{{.State.Health.Status}}" $Name 2>$null
    if ($h -eq "healthy") { break }
    Start-Sleep -Seconds 1
  }
  Write-Host "DB is healthy ✅"
}

function Exec-Psql {
  param(
    [string]$Name,
    [string]$Sql,
    [switch]$TuplesOnly
  )

  $tFlag = if ($TuplesOnly) { "-t -A" } else { "" }

  # Important: PowerShell-safe execution. We pipe SQL via stdin to psql.
  # Also: Use -h 127.0.0.1 so it uses TCP inside the container.
  $cmd = "PGPASSWORD='$DbPassword' psql -h 127.0.0.1 -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -X -P pager=off $tFlag"

  $Sql | docker exec -i $Name /bin/sh -lc $cmd
}

# --- main ---
$cn = Get-DbContainerName -Name $ContainerName
Wait-DbHealthy -Name $cn

# 1) Enforce lockdown
$lockSql = @'
revoke usage on schema auth from anon;
revoke usage on schema auth from authenticated;
revoke usage on schema auth from public;

revoke all privileges on all tables    in schema auth from anon, authenticated, public;
revoke all privileges on all sequences in schema auth from anon, authenticated, public;
revoke all privileges on all functions in schema auth from anon, authenticated, public;
'@

Exec-Psql -Name $cn -Sql $lockSql | Out-Null

# 2) Verify
$checkSql = @'
select
  has_schema_privilege('anon','auth','USAGE') as anon_usage,
  has_schema_privilege('authenticated','auth','USAGE') as authenticated_usage,
  has_schema_privilege('public','auth','USAGE') as public_usage;
'@

$check = Exec-Psql -Name $cn -Sql $checkSql

# If any usage is still true, dump ACL and fail
if ($check -match '\bt\b') {
  Write-Host "AUTH LOCKDOWN FAILED ❌"
  Write-Host "---- schema usage ----"
  $check | Write-Host

  Write-Host "`n---- auth schema ACL ----"
  $aclSql = @"
select
  n.nspname,
  n.nspowner::regrole as owner,
  coalesce(array_to_string(n.nspacl, E'\n'), '(null)') as nspacl
from pg_namespace n
where n.nspname='auth';
"@
  $aclSql | docker exec -i $cn psql -U postgres -d $DbName -X -P pager=off | Write-Host

  throw "AUTH LOCKDOWN FAILED (anon/authenticated/public still have USAGE on auth schema)"
}

Write-Host "AUTH LOCKDOWN OK ✅ (anon/authenticated/public have no USAGE on auth schema)"
