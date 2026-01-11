# tools/local/reset_and_lock_auth.ps1
# CANONICAL: reset local DB then enforce auth lockdown using privileged supabase_admin
# Policy: SQL migrations must not brick local runs; enforcement happens here.

[CmdletBinding()]
param(
  [string]$RepoRoot = (Get-Location).Path,
  [string]$DbPassword = "postgres",
  [string]$DbName = "postgres"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "Resetting local database..."
supabase db reset

# Find DB container
$ContainerName = (docker ps --format "{{.Names}}" | Select-String -Pattern "supabase_db_" | Select-Object -First 1).ToString().Trim()
if (-not $ContainerName) { throw "Could not find supabase_db_ container. Is supabase running?" }

Write-Host "DB container: $ContainerName"
Write-Host "Waiting for DB container healthy..."
while ($true) {
  $status = docker ps --format "{{.Names}}|{{.Status}}" |
    Select-String -SimpleMatch "$ContainerName|" |
    ForEach-Object { $_.ToString() }

  if ($status -match "healthy") { break }
  Start-Sleep -Seconds 1
}
Write-Host "DB is healthy ✅"

# Enforce auth lockdown using privileged script (supabase_admin)
Write-Host "Applying post-reset auth lockdown via tools/local/post_reset_lock_auth.ps1 ..."
pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoRoot "tools\local\post_reset_lock_auth.ps1") -DbPassword $DbPassword

# Verify
$check = @"
select
  (not has_schema_privilege('anon','auth','USAGE'))
  and (not has_schema_privilege('authenticated','auth','USAGE'))
  and (not has_schema_privilege('public','auth','USAGE'))
as ok;
"@

$out = $check | docker exec -i $ContainerName psql -U postgres -d $DbName -X -P pager=off -t -A
$ok = $out.Trim()

if ($ok -ne "t") {
  Write-Host "AUTH LOCKDOWN FAILED ❌  (ok=$ok)"
  @"
select
  has_schema_privilege('anon','auth','USAGE') as anon_auth_usage,
  has_schema_privilege('authenticated','auth','USAGE') as authenticated_auth_usage,
  has_schema_privilege('public','auth','USAGE') as public_auth_usage;
"@ | docker exec -i $ContainerName psql -U postgres -d $DbName -X -P pager=off

  throw "AUTH LOCKDOWN FAILED (expected ok=t)"
}

Write-Host "AUTH LOCKDOWN OK ✅ (anon/authenticated/public have no USAGE on auth schema)"
