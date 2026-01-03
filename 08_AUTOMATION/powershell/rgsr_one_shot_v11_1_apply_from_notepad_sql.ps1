param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [Parameter(Mandatory)][string]$ProjectRef
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

# --- locations ---
$mgDir = Join-Path $RepoRoot "supabase\migrations"
EnsureDir $mgDir

$sqlDir = Join-Path $RepoRoot "08_AUTOMATION\sql"
EnsureDir $sqlDir

$srcSql = Join-Path $sqlDir "rgsr_v11_1_scene_impact_forum_lockin.sql"
if (-not (Test-Path -LiteralPath $srcSql)) {
  throw "Missing SQL file: $srcSql`nCreate it in Notepad (UTF-8) and paste the v11.1 SQL."
}

# --- sanity: make sure SQL is not empty ---
$srcLen = (Get-Item -LiteralPath $srcSql).Length
if ($srcLen -lt 1000) {
  throw "SQL file looks too small ($srcLen bytes). It should be the full v11.1 migration content."
}

# --- create migration ---
$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_v11_1_scene_impact_forum_lockin.sql" -f $MigrationId)

Copy-Item -LiteralPath $srcSql -Destination $mgPath -Force
Write-Host ("[OK] MIGRATION WRITTEN: " + $mgPath + " (" + $srcLen + " bytes)") -ForegroundColor Green

# --- supabase link ---
& supabase link --project-ref $ProjectRef
if ($LASTEXITCODE -ne 0) { throw "supabase link failed (exit=$LASTEXITCODE)" }
Write-Host "[OK] supabase link complete" -ForegroundColor Green

# --- push (auto-yes) ---
cmd /c "echo y| supabase db push" | Out-Host
if ($LASTEXITCODE -ne 0) { throw "supabase db push failed (exit=$LASTEXITCODE)" }
Write-Host "[OK] supabase db push complete" -ForegroundColor Green

Write-Host "✅ v11.1 applied from Notepad SQL (scene + impact + forum)" -ForegroundColor Green
