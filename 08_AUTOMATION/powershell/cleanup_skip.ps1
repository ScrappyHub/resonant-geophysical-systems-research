Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repo = (git rev-parse --show-toplevel).Trim()
if (-not $repo) { throw "Not in a git repo." }

$mg   = Join-Path $repo "supabase\migrations"
$dead = Join-Path $repo "supabase\migrations_disabled"
New-Item -ItemType Directory -Force -Path $dead | Out-Null

# Find any "SKIP" migrations (any timestamp) safely
$skip = @(Get-ChildItem -LiteralPath $mg -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '\.SKIP(_|$)' })

if ($skip.Count -eq 0) {
  Write-Host "[OK] No SKIP migrations in supabase\migrations (already clean)." -ForegroundColor Green
  exit 0
}

if ($skip.Count -gt 1) {
  Write-Host "[WARN] Multiple SKIP files found; moving ALL to migrations_disabled:" -ForegroundColor Yellow
}

foreach ($f in $skip) {
  $dest = Join-Path $dead $f.Name
  Move-Item -LiteralPath $f.FullName -Destination $dest -Force
  Write-Host ("[OK] moved -> " + $dest) -ForegroundColor Green
}

Write-Host "[DONE] SKIP migrations moved out of migrations folder." -ForegroundColor Green
