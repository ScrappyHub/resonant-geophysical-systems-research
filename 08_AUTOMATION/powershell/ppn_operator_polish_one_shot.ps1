param(
  [string]$RepoRoot = "M:\Plantery Pyramid Network",
  [switch]$RunDocsOneShot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Msg) { throw $Msg }

function ReadUtf8([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { Fail "Missing file: $Path" }
  return Get-Content -LiteralPath $Path -Raw -Encoding UTF8
}

function WriteUtf8([string]$Path, [string]$Content) {
  $d = Split-Path -Parent $Path
  if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  Set-Content -LiteralPath $Path -Encoding UTF8 -Value $Content
  if (-not (Test-Path -LiteralPath $Path)) { Fail "Failed to write: $Path" }
}

function InsertAfter([string]$Text, [string]$Needle, [string]$Insert) {
  $idx = $Text.IndexOf($Needle, [StringComparison]::Ordinal)
  if ($idx -lt 0) { return $null }
  $pos = $idx + $Needle.Length
  return $Text.Substring(0,$pos) + $Insert + $Text.Substring($pos)
}

function InsertBefore([string]$Text, [string]$Needle, [string]$Insert) {
  $idx = $Text.IndexOf($Needle, [StringComparison]::Ordinal)
  if ($idx -lt 0) { return $null }
  return $Text.Substring(0,$idx) + $Insert + $Text.Substring($idx)
}

function RemoveLineContaining([string]$Text, [string]$Token) {
  $lines = $Text -split "\r?\n", -1
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($ln in $lines) {
    if ($ln -like ("*" + $Token + "*")) { continue }
    $out.Add($ln) | Out-Null
  }
  return ($out -join "`r`n")
}

function TryInsertAtAnyAnchor([string]$Text, [string[]]$Anchors, [string]$Insert, [ref]$UsedAnchor) {
  foreach ($a in $Anchors) {
    $tmp = InsertBefore $Text $a $Insert
    if ($tmp) { $UsedAnchor.Value = $a; return $tmp }
  }
  return $null
}

function TryInsertAfterAnyAnchor([string]$Text, [string[]]$Anchors, [string]$Insert, [ref]$UsedAnchor) {
  foreach ($a in $Anchors) {
    $tmp = InsertAfter $Text $a $Insert
    if ($tmp) { $UsedAnchor.Value = $a; return $tmp }
  }
  return $null
}

if (-not (Test-Path -LiteralPath $RepoRoot)) { Fail "Missing RepoRoot: $RepoRoot" }

$packetPath = Join-Path $RepoRoot "08_AUTOMATION\powershell\ppn_ab_packet.ps1"
$raw = ReadUtf8 $packetPath

$marker = "# ---- BundleDir (operator-grade): auto-pick latest P1 export bundle if not provided ----"
if ($raw -notlike ("*" + $marker + "*")) {

  # 1) Make BundleDir param optional (line-based rewrite; no regex)
  $lines = $raw -split "\r?\n", -1
  for ($i=0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -like "*`$BundleDir*" -and $ln -like "*=*" -and $ln -like "*resonance_engine_v1_bundle_*") {
      $eq = $ln.IndexOf("=", [StringComparison]::Ordinal)
      if ($eq -gt 0) { $lines[$i] = $ln.Substring(0, $eq).TrimEnd() }
    }
  }
  $raw = ($lines -join "`r`n")

  # 2) Remove any pre-bundle bestBandPath assignment referencing BundleDir
  $raw = RemoveLineContaining $raw '$bestBandPath = Join-Path $BundleDir "best_band.txt"'

  # 3) Build operator-grade auto-pick bundle block
  $block = @(
    ""
    $marker
    '$exportsRoot = Join-Path $RepoRoot ("05_ANALYSIS\REPORTS\{0}\_EXPORTS" -f $P1)'
    ""
    'if (-not $PSBoundParameters.ContainsKey("BundleDir") -or [string]::IsNullOrWhiteSpace($BundleDir)) {'
    '  if (-not (Test-Path -LiteralPath $exportsRoot)) { throw ("Missing exports root for P1: " + $exportsRoot) }'
    '  $candidate = Get-ChildItem -LiteralPath $exportsRoot -Directory -ErrorAction Stop |'
    '    Where-Object { $_.Name -like "resonance_engine_v1_bundle_*" } |'
    '    Sort-Object LastWriteTime -Descending |'
    '    Select-Object -First 1'
    '  if (-not $candidate) { throw ("No export bundles found under: " + $exportsRoot) }'
    '  $BundleDir = $candidate.FullName'
    '}'
    ""
    '$bestBandPath = Join-Path $BundleDir "best_band.txt"'
    'if (-not (Test-Path -LiteralPath $BundleDir)) { throw ("Missing BundleDir: " + $BundleDir) }'
    'if (-not (Test-Path -LiteralPath $bestBandPath)) { throw ("Missing best_band.txt in bundle: " + $bestBandPath) }'
    'Write-Host ("[PPN] BundleDir -> " + $BundleDir) -ForegroundColor DarkCyan'
    ""
  ) -join "`r`n"

  # 4) Insert using robust anchor fallback list
  $used = ""
  $primaryAnchors = @(
    "# ---- SAFETY CHECKS ----",
    "# ---- SAFETY CHECKS",
    "# ---- Ensure P2 outputs exist ----",
    "# ---- Ensure P2 outputs exist",
    "# ---- PATHS ----",
    "# ---- PATHS"
  )

  $raw2 = TryInsertAtAnyAnchor $raw $primaryAnchors $block ([ref]$used)

  if (-not $raw2) {
    # fallback: insert after $sumFile line (stable)
    $afterAnchors = @(
      '$sumFile = Join-Path $p2AB "SHA256SUMS.txt"',
      '$sumFile= Join-Path $p2AB "SHA256SUMS.txt"'
    )
    $raw2 = TryInsertAfterAnyAnchor $raw $afterAnchors ($block + "`r`n") ([ref]$used)
  }

  if (-not $raw2) { Fail "Operator polish: no valid insertion anchor found (SAFETY/PATHS/sumFile missing)." }

  $raw = $raw2
  Write-Host ("[PPN] Inserted operator bundle auto-pick block using anchor: " + $used) -ForegroundColor DarkGreen
}

if ($raw -notlike ("*" + $marker + "*")) { Fail "Operator polish patch failed: marker missing after patch." }

WriteUtf8 $packetPath $raw
Write-Host "✓ Patched: 08_AUTOMATION\powershell\ppn_ab_packet.ps1" -ForegroundColor Green

if ($RunDocsOneShot) {
  $docsRunner = Join-Path $RepoRoot "08_AUTOMATION\powershell\ppn_docs_one_shot.ps1"
  if (-not (Test-Path -LiteralPath $docsRunner)) { Fail "Docs runner missing: $docsRunner" }
  Write-Host "`n[PPN] Running docs one-shot..." -ForegroundColor Cyan
  pwsh -NoProfile -ExecutionPolicy Bypass -File $docsRunner -RepoRoot $RepoRoot -EnableRunnerTempCleanup
  if ($LASTEXITCODE -ne 0) { Fail "Docs one-shot failed (exit=$LASTEXITCODE)." }
}

Write-Host "`n✅ PPN OPERATOR POLISH ONE-SHOT COMPLETE" -ForegroundColor Green
