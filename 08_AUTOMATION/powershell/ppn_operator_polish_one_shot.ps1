param(
  [string]$RepoRoot = "M:\Plantery Pyramid Network",
  [switch]$RunDocsOneShot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Msg) { throw $Msg }

function ReadUtf8([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { Fail "Missing file: $Path" }
  Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function WriteUtf8([string]$Path, [string]$Content) {
  $d = Split-Path -Parent $Path
  if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  Set-Content -LiteralPath $Path -Encoding UTF8 -Value $Content
  if (-not (Test-Path -LiteralPath $Path)) { Fail "Failed to write: $Path" }
}

$packetPath = Join-Path $RepoRoot "08_AUTOMATION\powershell\ppn_ab_packet.ps1"
$raw = ReadUtf8 $packetPath

$marker = "# ---- BundleDir (operator-grade): auto-pick latest P1 export bundle if not provided ----"

if ($raw -notlike ("*" + $marker + "*")) {

  $block = @(
    $marker
    '$exportsRoot = Join-Path $RepoRoot ("05_ANALYSIS\REPORTS\{0}\_EXPORTS" -f $P1)'
    'if (-not $PSBoundParameters.ContainsKey("BundleDir") -or [string]::IsNullOrWhiteSpace($BundleDir)) {'
    '  if (-not (Test-Path -LiteralPath $exportsRoot)) { throw ("Missing exports root for P1: " + $exportsRoot) }'
    '  $candidate = Get-ChildItem -LiteralPath $exportsRoot -Directory |'
    '    Where-Object { $_.Name -like "resonance_engine_v1_bundle_*" } |'
    '    Sort-Object LastWriteTime -Descending | Select-Object -First 1'
    '  if (-not $candidate) { throw ("No export bundles found under: " + $exportsRoot) }'
    '  $BundleDir = $candidate.FullName'
    '}'
    '$bestBandPath = Join-Path $BundleDir "best_band.txt"'
    'if (-not (Test-Path -LiteralPath $bestBandPath)) { throw ("Missing best_band.txt in bundle: " + $bestBandPath) }'
    'Write-Host ("[PPN] BundleDir -> " + $BundleDir) -ForegroundColor DarkCyan'
    ''
  ) -join "`r`n"

  # --- RANGE-SAFE PREPEND AFTER LEADING COMMENT LINES ---
  $lines = $raw -split "\r?\n", -1

  $i = 0
  while ($i -lt $lines.Count -and $lines[$i].Trim().StartsWith("#")) { $i++ }

  $head = ""
  if ($i -gt 0) { $head = ($lines[0..($i-1)] -join "`r`n") }

  $tail = ""
  if ($i -le ($lines.Count - 1)) { $tail = ($lines[$i..($lines.Count-1)] -join "`r`n") }

  if ([string]::IsNullOrEmpty($head)) {
    $raw = $block + "`r`n" + $tail
  } else {
    $raw = $head + "`r`n" + $block + "`r`n" + $tail
  }
}

if ($raw -notlike ("*" + $marker + "*")) { Fail "Operator polish failed: marker missing after prepend." }

WriteUtf8 $packetPath $raw
Write-Host "✓ Patched (prepend-safe): ppn_ab_packet.ps1" -ForegroundColor Green

if ($RunDocsOneShot) {
  $docs = Join-Path $RepoRoot "08_AUTOMATION\powershell\ppn_docs_one_shot.ps1"
  if (-not (Test-Path -LiteralPath $docs)) { Fail "Docs runner missing: $docs" }
  Write-Host "`n[PPN] Running docs one-shot..." -ForegroundColor Cyan
  pwsh -NoProfile -ExecutionPolicy Bypass -File $docs -RepoRoot $RepoRoot -EnableRunnerTempCleanup
  if ($LASTEXITCODE -ne 0) { Fail "Docs one-shot failed (exit=$LASTEXITCODE)." }
}

Write-Host "`n✅ PPN OPERATOR POLISH — PREPEND MODE COMPLETE" -ForegroundColor Green
