# tools/local/run_determinism_tests.ps1
# CANONICAL: one command to prove replay determinism
# - runs SQL tests
# - optionally verifies one or more engine_run_ids via rgsr.replay_verify_engine_run()

[CmdletBinding()]
param(
  [string]$DbName = "postgres",
  [string]$DbUser = "postgres",
  [string]$DbPassword = "postgres",
  [string]$TestsPath = ".\supabase\tests\rgsr_replay_determinism.sql",
  [string[]]$VerifyRunIds = @()  # pass explicit UUIDs to verify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DbContainerName {
  $cn = (docker ps --format "{{.Names}}" | Select-String -Pattern "supabase_db_" | Select-Object -First 1).ToString().Trim()
  if (-not $cn) { throw "Could not find supabase_db_ container. Is supabase running?" }
  return $cn
}

$cn = Get-DbContainerName
Write-Host "DB container: $cn"

if (-not (Test-Path $TestsPath)) {
  throw "Tests file not found: $TestsPath"
}

Write-Host "Running SQL determinism tests: $TestsPath"
$testSql = Get-Content -Raw -LiteralPath $TestsPath

# Run tests (ON_ERROR_STOP=1)
$null = $testSql | docker exec -i $cn /bin/sh -lc "PGPASSWORD=$DbPassword psql -h 127.0.0.1 -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -X -P pager=off"

Write-Host "SQL tests OK ✅"

# Optional: verify specific runs via RPC
foreach ($id in $VerifyRunIds) {
  Write-Host "Verifying engine_run_id: $id"
  $sql = @"
select rgsr.replay_verify_engine_run('$id'::uuid) as result;
"@
  $out = $sql | docker exec -i $cn /bin/sh -lc "PGPASSWORD=$DbPassword psql -h 127.0.0.1 -U $DbUser -d $DbName -v ON_ERROR_STOP=1 -X -P pager=off -t -A"
  $out = $out.Trim()
  if (-not $out) { throw "RPC returned no output for $id" }

  # Quick pass/fail parse: require '"ok": true'
  if ($out -notmatch '"ok"\s*:\s*true') {
    Write-Host $out
    throw "Replay verification FAILED for $id"
  }

  Write-Host "Replay verification OK ✅ ($id)"
}

Write-Host "Determinism verification complete ✅"
