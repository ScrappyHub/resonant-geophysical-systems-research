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

function RemoveLinesLike([string]$Text, [string]$LikePattern) {
  $lines = $Text -split "\r?\n", -1
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($ln in $lines) {
    if ($ln -like $LikePattern) { continue }
    $out.Add($ln) | Out-Null
  }
  return ($out -join "`r`n")
}

function InsertBlockAfterFirstMatch([string]$Text, [string]$LikePattern, [string]$Block, [ref]$UsedLabel) {
  $lines = $Text -split "\r?\n", -1
  for ($i=0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -like $LikePattern) {
      $UsedLabel.Value = "after match: $LikePattern (line " + ($i+1) + ")"
      $head = $lines[0..$i] -join "`r`n"
      $tail = ""
      if ($i+1 -le $lines.Count-1) { $tail = ($lines[($i+1)..($lines.Count-1)] -join "`r`n") }
      if ($tail.Length -gt 0) { return ($head + "`r`n" + $Block + "`r`n" + $tail) }
      return ($head + "`r`n" + $Block + "`r`n")
    }
  }
  return $null
}

function InsertBlockAfterParamClose([string]$Text, [string]$Block, [ref]$UsedLabel) {
  # Find first line that is exactly ')' after a 'param(' line (very common structure)
  $lines = $Text -split "\r?\n", -1
  $seenParam = $false
  for ($i=0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i].Trim()
    if (-not $seenParam -and $ln -like "param(*") { $seenParam = $true; continue }
    if ($seenParam -and $ln -eq ")") {
      $UsedLabel.Value = "after param() close (line " + ($i+1) + ")"
      $head = $lines[0..$i] -join "`r`n"
      $tail = ""
      if ($i+1 -le $lines.Count-1) { $tail = ($lines[($i+1)..($lines.Count-1)] -join "`r`n") }
      if ($tail.Length -gt 0) { return ($head + "`r`n" + $Block + "`r`n" + $tail) }
      return ($head + "`r`n" + $Block + "`r`n")
    }
  }
  return $null
}

function PrintDebugCandidates([string]$Text) {
  Write-Host "`n[PPN] DEBUG CANDIDATE LINES (automatic)" -ForegroundColor Yellow
  $lines = $Text -split "\r?\n", -1
  $needles = @("PATHS","SHA","sumFile","_AB_COMPARE","BundleDir","best_band")
  for ($i=0; $i -lt $lines.Count; $i++) {
    foreach ($n in $needles) {
      if ($lines[$i] -like ("*" + $n + "*")) {
        $msg = ("L{0:0000}: {1}" -f ($i+1), $lines[$i])
        Write-Host $msg -ForegroundColor DarkYellow
        break
      }
    }
  }
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
    # any BundleDir param line that includes an '=' assignment becomes just the left side
    if ($ln -like "*[string]*`$BundleDir*" -and $ln -like "*=*" ) {
      $eq = $ln.IndexOf("=", [StringComparison]::Ordinal)
      if ($eq -gt 0) { $lines[$i] = $ln.Substring(0, $eq).TrimEnd() }
    }
  }
  $raw = ($lines -join "`r`n")

  # 2) Remove any pre-bundle bestBandPath assignment referencing BundleDir
  $raw = RemoveLinesLike $raw "*bestBandPath*BundleDir*best_band.txt*"

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

  # 4) Insert block using line-scan anchors (wildcards), then param() close fallback
  $used = ""
  $raw2 = $null

  $raw2 = InsertBlockAfterFirstMatch $raw "*SHA256SUMS*" $block ([ref]$used)
  if (-not $raw2) { $raw2 = InsertBlockAfterFirstMatch $raw "*`$sumFile*" $block ([ref]$used) }
  if (-not $raw2) { $raw2 = InsertBlockAfterFirstMatch $raw "*_AB_COMPARE*" $block ([ref]$used) }
  if (-not $raw2) { $raw2 = InsertBlockAfterFirstMatch $raw "*# ---- PATHS*" $block ([ref]$used) }
  if (-not $raw2) { $raw2 = InsertBlockAfterParamClose $raw $block ([ref]$used) }

  if (-not $raw2) {
    PrintDebugCandidates $raw
    Fail "Operator polish: no valid insertion anchor found (SHA256SUMS/sumFile/_AB_COMPARE/PATHS/param-close missing)."
  }

  $raw = $raw2
  Write-Host ("[PPN] Inserted operator bundle auto-pick block (" + $used + ")") -ForegroundColor DarkGreen
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
