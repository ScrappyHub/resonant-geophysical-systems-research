# ============================================================
# PPN CANONICAL ONE-SHOT PIPELINE (AUTO-DISCOVER P2s)
# - Discovers P2 experiments from: 04_DATA\RAW\PPN-P2-*
# - Builds A/B packets for each discovered P2
# - Hard-fails on real build errors
# - Optional: contains/moves stray quarantine folder into repo
# - FIXED: robust -Only filter parsing
# ============================================================

[CmdletBinding()]
param(
  [Parameter()][string]$RepoRoot = "M:\Plantery Pyramid Network",
  [Parameter()][string[]]$Only
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptPath     = Join-Path $RepoRoot "08_AUTOMATION\powershell\ppn_ab_packet.ps1"
$QuarantineSrc  = "M:\_QUARANTINE_ROOTED_FROM_PPN"
$QuarantineDst  = Join-Path $RepoRoot "_QUARANTINE_ROOTED_FROM_PPN"
$RawRoot        = Join-Path $RepoRoot "04_DATA\RAW"

if (-not (Test-Path -LiteralPath $RepoRoot))   { throw "Missing RepoRoot: $RepoRoot" }
if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Missing script: $ScriptPath" }
if (-not (Test-Path -LiteralPath $RawRoot))    { throw "Missing RAW root: $RawRoot" }

$info = Get-Item -LiteralPath $ScriptPath
Write-Host ("✅ Script -> {0} (bytes={1})" -f $info.FullName, $info.Length) -ForegroundColor Green
if ($info.Length -lt 5000) { throw "ppn_ab_packet.ps1 looks stub-sized ($($info.Length) bytes)." }

# Contain quarantine folder if present
if (Test-Path -LiteralPath $QuarantineSrc) {
  New-Item -ItemType Directory -Force -Path $QuarantineDst | Out-Null
  Move-Item -LiteralPath $QuarantineSrc -Destination $QuarantineDst
  Write-Host "✅ Moved quarantine folder into repo -> $QuarantineDst" -ForegroundColor Green
} else {
  Write-Host "ℹ️ No quarantine folder at drive root (good)." -ForegroundColor DarkGray
}

# Discover P2s from RAW
$P2Ids = Get-ChildItem -LiteralPath $RawRoot -Directory |
  Where-Object { $_.Name -match '^PPN-P2-\d{4}$' } |
  Sort-Object Name |
  ForEach-Object { $_.Name }

# ---- Robust -Only parsing ----
# Accept:
#   -Only "PPN-P2-0002","PPN-P2-0001"
#   -Only PPN-P2-0002,PPN-P2-0001
# and ignore whitespace
$OnlyFlat = @()
if ($PSBoundParameters.ContainsKey('Only') -and $Only) {
  foreach ($item in $Only) {
    if ($null -eq $item) { continue }
    foreach ($tok in ($item -split '\s*,\s*')) {
      $t = $tok.Trim()
      if ($t) { $OnlyFlat += $t }
    }
  }
}

Write-Host ("ℹ️ RAW discovered count: {0}" -f $P2Ids.Count) -ForegroundColor DarkGray
if ($OnlyFlat.Count -gt 0) {
  Write-Host ("ℹ️ -Only requested: {0}" -f ($OnlyFlat -join ", ")) -ForegroundColor DarkGray
  $onlySet = @{}
  foreach ($x in $OnlyFlat) { $onlySet[$x] = $true }
  $P2Ids = $P2Ids | Where-Object { $onlySet.ContainsKey($_) }
}

if (-not $P2Ids -or $P2Ids.Count -eq 0) {
  Write-Host "ℹ️ No matching P2 RAW folders found under: $RawRoot" -ForegroundColor Yellow
  return
}

Write-Host "`n[PPN] Discovered P2s:" -ForegroundColor Cyan
$P2Ids | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Cyan }

$results = New-Object System.Collections.Generic.List[object]

foreach ($p2 in $P2Ids) {
  Write-Host ("`n[PPN] BUILD -> {0}" -f $p2) -ForegroundColor Cyan

  pwsh -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -P2 $p2
  if ($LASTEXITCODE -ne 0) { throw "ppn_ab_packet.ps1 failed for $p2 (exit=$LASTEXITCODE)." }

  $outDir = Join-Path $RepoRoot ("05_ANALYSIS\REPORTS\{0}\_AB_COMPARE" -f $p2)
  if (-not (Test-Path -LiteralPath $outDir)) { throw "Expected output dir missing after build: $outDir" }

  $hash = Join-Path $outDir "SHA256SUMS.txt"
  if (-not (Test-Path -LiteralPath $hash)) { throw "Expected hashes missing: $hash" }

  $results.Add([pscustomobject]@{ P2=$p2; Status="OK"; Note=$outDir }) | Out-Null
}

Write-Host "`n================ SUMMARY ================" -ForegroundColor Green
$results | Format-Table -AutoSize

Write-Host "`n✅ ONE-SHOT COMPLETE" -ForegroundColor Green

# ----- PPN TEMP CLEANUP (canonical) -----
try {
  Get-ChildItem -LiteralPath $env:TEMP -Filter "ppn_ab_compare_*.py" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  Get-ChildItem -LiteralPath $env:TEMP -Filter "ppn_ab_plots_*.py"   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  Write-Host "✓ PPN TEMP CLEANUP: removed temp python files" -ForegroundColor DarkGreen
} catch {
  $msg = $_.Exception.Message
  Write-Host "ℹ PPN TEMP CLEANUP skipped (non-fatal): $msg" -ForegroundColor DarkGray
}

