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
function ReplaceAll([string]$Text, [string]$Old, [string]$New) {
  if ([string]::IsNullOrEmpty($Old)) { Fail "ReplaceAll: Old is empty" }
  return $Text.Replace($Old, $New)
}
function InsertBefore([string]$Text, [string]$Needle, [string]$Insert) {
  $idx = $Text.IndexOf($Needle, [StringComparison]::Ordinal)
  if ($idx -lt 0) { Fail "InsertBefore: anchor not found: $Needle" }
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

if (-not (Test-Path -LiteralPath $RepoRoot)) { Fail "Missing RepoRoot: $RepoRoot" }

$packetPath = Join-Path $RepoRoot "08_AUTOMATION\powershell\ppn_ab_packet.ps1"
$raw = ReadUtf8 $packetPath

$marker = "# ---- BundleDir (operator-grade): auto-pick latest P1 export bundle if not provided ----"
if ($raw -notlike ("*" + $marker + "*")) {

  # 1) Make BundleDir param optional by line-based rewrite (no regex)
  # Find the param line that contains $BundleDir = "..." and strip the default assignment.
  $lines = $raw -split "\r?\n", -1
  for ($i=0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -like "*`$BundleDir*" -and $ln -like "*=*" -and $ln -like "*resonance_engine_v1_bundle_*") {
      # Convert e.g.  [Parameter()][string]$BundleDir = "C:\..."  ->  [Parameter()][string]$BundleDir
      $eq = $ln.IndexOf("=", [StringComparison]::Ordinal)
      if ($eq -gt 0) {
        $lines[$i] = $ln.Substring(0, $eq).TrimEnd()
      }
    }
  }
  $raw = ($lines -join "`r`n")

  # 2) Remove any pre-bundle bestBandPath assignment that references $BundleDir
  $raw = RemoveLineContaining $raw "`$bestBandPath = Join-Path `$BundleDir `"best_band.txt`""

  # 3) Insert bundle auto-pick block before SAFETY CHECKS anchor
  $anchor = "# ---- SAFETY CHECKS ----"
  $block = @(
    "",
    $marker,
    "`$exportsRoot = Join-Path `$RepoRoot (""05_ANALYSIS\REPORTS\{0}\_EXPORTS"" -f `$P1)",
    "",
    "if (-not `$PSBoundParameters.ContainsKey('BundleDir') -or [string]::IsNullOrWhiteSpace(`$BundleDir)) {",
    "  if (-not (Test-Path -LiteralPath `$exportsRoot)) { throw ""Missing exports root for P1: `$exportsRoot"" }",
    "",
    "  `$candidate = Get-ChildItem -LiteralPath `$exportsRoot -Directory -ErrorAction Stop |",
    "    Where-Object { `$\_.Name -like ""resonance_engine_v1_bundle_*"" } |",
    "    Sort-Object LastWriteTime -Descending |",
    "    Select-Object -First 1",
    "",
    "  if (-not `$candidate) { throw ""No export bundles found under: `$exportsRoot"" }",
    "  `$BundleDir = `$candidate.FullName",
    "}",
    "",
    "`$bestBandPath = Join-Path `$BundleDir ""best_band.txt""",
    "if (-not (Test-Path -LiteralPath `$BundleDir)) { throw ""Missing BundleDir: `$BundleDir"" }",
    "if (-not (Test-Path -LiteralPath `$bestBandPath)) { throw ""Missing best_band.txt in bundle: `$bestBandPath"" }",
    "Write-Host ""[PPN] BundleDir -> `$BundleDir"" -ForegroundColor DarkCyan",
    ""
  ) -join "`r`n"

  $raw = InsertBefore $raw $anchor $block
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
