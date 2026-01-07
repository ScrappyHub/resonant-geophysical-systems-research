param(
  [string]$RunName = ("run_" + (Get-Date -Format "yyyyMMdd_HHmmss")),
  [switch]$DoDbReset
)

$ErrorActionPreference = "Stop"

$root = git rev-parse --show-toplevel
if (-not $root) { throw "Not in a git repo." }
Set-Location $root

$out = Join-Path $root ("_rgsr_reports\" + $RunName)
New-Item -ItemType Directory -Force -Path $out | Out-Null

"CORE AUDIT RUN: $RunName" | Set-Content -Encoding UTF8 (Join-Path $out "RUN_HEADER.txt")
git rev-parse HEAD     | Set-Content -Encoding UTF8 (Join-Path $out "GIT_SHA.txt")
git status --porcelain | Set-Content -Encoding UTF8 (Join-Path $out "GIT_STATUS.txt")
supabase status        | Out-File -Encoding utf8 (Join-Path $out "SUPABASE_STATUS.txt")

if ($DoDbReset) {
  "DB RESET: YES" | Add-Content (Join-Path $out "RUN_HEADER.txt")
  supabase db reset | Out-File -Encoding utf8 (Join-Path $out "SUPABASE_DB_RESET.txt")
}

$pg = docker ps --format "{{.Names}}" | Select-String -Pattern "supabase_db_"
if (-not $pg) { throw "Could not find supabase db container. Run: supabase start" }
$PG_CONTAINER = $pg.ToString().Trim()

$Sql = @"
\pset pager off
select now() as captured_at;
select exists(
  select 1
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='core' and p.proname='instrument_mode_enabled'
) as has_instrument_mode_enabled;
"@

$Sql | docker exec -i $PG_CONTAINER psql -U postgres -d postgres -v ON_ERROR_STOP=1 |
  Out-File -Encoding utf8 (Join-Path $out "DB_SNAPSHOT.txt")

$hashPath = Join-Path $out "SHA256SUMS.txt"
Get-ChildItem -Recurse -File $out | ForEach-Object {
  $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLower()
  $rel = $_.FullName.Replace($out + "\", "")
  "$h  $rel"
} | Set-Content -Encoding UTF8 -LiteralPath $hashPath

Write-Host "AUDIT RUN COMPLETE: $out"
Write-Host "Hashes: $hashPath"
