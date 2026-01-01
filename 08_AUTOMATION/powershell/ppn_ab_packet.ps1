param(
  [string]$RepoRoot = "M:\Plantery Pyramid Network",
  [switch]$EnableRunnerTempCleanup,
  [switch]$NoReadmeWrite = $false,
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$DocsRoot   = Join-Path $RepoRoot "09_DOCS\CANONICAL"
$ReadmePath = Join-Path $RepoRoot "README.md"
$RunnerPath = Join-Path $RepoRoot "08_AUTOMATION\powershell\ppn_ab_one_shot.ps1"

if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "Missing RepoRoot: $RepoRoot" }
New-Item -ItemType Directory -Force -Path $DocsRoot | Out-Null

function Write-FileUtf8([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Set-Content -LiteralPath $Path -Encoding UTF8 -Value $Content
  if (-not (Test-Path -LiteralPath $Path)) { throw "Failed to write: $Path" }
}

# ----------------------------
# DOC CONTENT (no here-strings)
# ----------------------------
$masterIndex = @(
  "# PPN Master Index (Operator Entry Point)",
  "",
  "Operator-grade docs so another engineer can run, verify, and extend PPN without touching canonical 1-10 files.",
  "",
  "## Quick Start",
  "- One-Shot A/B Builder:",
  "  - pwsh -NoProfile -ExecutionPolicy Bypass -File ""08_AUTOMATION\powershell\ppn_ab_one_shot.ps1""",
  "  - pwsh -NoProfile -ExecutionPolicy Bypass -File ""08_AUTOMATION\powershell\ppn_ab_one_shot.ps1"" -Only ""PPN-P2-0002"",""PPN-P2-0001""",
  "",
  "## Documents",
  "- CANONICAL_COMMANDS.md",
  "- TESTING_PLAYBOOK.md",
  "- DATA_FLOWS.md",
  "- ANOMALY_CATALOG.md",
  "- GLOSSARY.md",
  "",
  "## Repo Structure (high level)",
  "- 04_DATA\RAW\PPN-P2-****  (existence gate)",
  "- 04_DATA\PROCESSED\PPN-*\resonance_engine_v1\resonance_sweep.csv",
  "- 05_ANALYSIS\REPORTS\PPN-P2-****\_AB_COMPARE\",
  "- 08_AUTOMATION\powershell\"
) -join "`r`n"

$commands = @(
  "# Canonical Commands (PPN)",
  "",
  "## A/B Packet Builder (single P2)",
  "pwsh -NoProfile -ExecutionPolicy Bypass -File ""08_AUTOMATION\powershell\ppn_ab_packet.ps1"" -P2 ""PPN-P2-0002""",
  "",
  "## One-Shot (auto-discover all P2 RAW)",
  "pwsh -NoProfile -ExecutionPolicy Bypass -File ""08_AUTOMATION\powershell\ppn_ab_one_shot.ps1""",
  "",
  "## One-Shot (Only list)",
  "pwsh -NoProfile -ExecutionPolicy Bypass -File ""08_AUTOMATION\powershell\ppn_ab_one_shot.ps1"" -Only ""PPN-P2-0002"",""PPN-P2-0001""",
  "",
  "## Golden rules",
  "- RAW presence is the existence gate.",
  "- Do not hand-edit generated packets; regenerate."
) -join "`r`n"

$flows = @(
  "# Data Flows (PPN)",
  "",
  "1) RAW:       04_DATA\RAW\PPN-P2-****",
  "2) PROCESSED: 04_DATA\PROCESSED\PPN-*\resonance_engine_v1\resonance_sweep.csv",
  "3) REPORTS:   05_ANALYSIS\REPORTS\PPN-P2-****\_AB_COMPARE\"
) -join "`r`n"

$anomaly = @(
  "# Anomaly Catalog (PPN)",
  "",
  "## Missing output",
  "- Likely: RAW/PROCESSED missing, bad path, upstream script failure.",
  "- Check: existence gate, processed sweep path, python/tool exit codes.",
  "",
  "## Flat deltas",
  "- Likely: comparing same dataset, join mismatch, constant columns.",
  "- Check: AB_inputs_pointer.txt, sweep row counts, drive_hz overlap.",
  "",
  "## In-band empty",
  "- Likely: band limits do not overlap drive_hz, filter window wrong.",
  "- Check: configured band vs drive_hz min/max."
) -join "`r`n"

$glossary = @(
  "# Glossary (PPN)",
  "- P1: baseline",
  "- P2: candidate",
  "- A/B packet: _AB_COMPARE bundle",
  "- drive_hz: sweep axis",
  "- delta: P2 - P1"
) -join "`r`n"

$playbook = @(
  "# Testing Playbook (PPN)",
  "",
  "Operator interpretation layer: what to look for, how to classify, and what results mean.",
  "",
  "## What to look for",
  "- Broadband shifts (system-wide)",
  "- Narrowband spikes (resonance behavior)",
  "- In-band mean/min/max changes (windowed effect)",
  "",
  "## What counts as real",
  "1) Repeatable",
  "2) Cross-metric confirmation",
  "3) Physically meaningful clustering (not single-point noise)"
) -join "`r`n"

Write-FileUtf8 (Join-Path $DocsRoot "MASTER_INDEX.md") $masterIndex
Write-FileUtf8 (Join-Path $DocsRoot "CANONICAL_COMMANDS.md") $commands
Write-FileUtf8 (Join-Path $DocsRoot "DATA_FLOWS.md") $flows
Write-FileUtf8 (Join-Path $DocsRoot "ANOMALY_CATALOG.md") $anomaly
Write-FileUtf8 (Join-Path $DocsRoot "GLOSSARY.md") $glossary
Write-FileUtf8 (Join-Path $DocsRoot "TESTING_PLAYBOOK.md") $playbook

# ----------------------------
# README SECTION (managed)
# ----------------------------
$sectionStart = "<!-- PPN_OPERATOR_DOCS_START -->"
$sectionEnd   = "<!-- PPN_OPERATOR_DOCS_END -->"
$readmeSection = @(
  $sectionStart,
  "## Operator Docs (PPN)",
  "Entry point: 09_DOCS\CANONICAL\MASTER_INDEX.md",
  "- Master Index: 09_DOCS\CANONICAL\MASTER_INDEX.md",
  "- Commands: 09_DOCS\CANONICAL\CANONICAL_COMMANDS.md",
  "- Playbook: 09_DOCS\CANONICAL\TESTING_PLAYBOOK.md",
  "- Data Flows: 09_DOCS\CANONICAL\DATA_FLOWS.md",
  "- Anomalies: 09_DOCS\CANONICAL\ANOMALY_CATALOG.md",
  "- Glossary: 09_DOCS\CANONICAL\GLOSSARY.md",
  $sectionEnd
) -join "`r`n"

if (Test-Path -LiteralPath $ReadmePath) { $r = Get-Content -LiteralPath $ReadmePath -Raw -Encoding UTF8 } else { $r = "# Plantery Pyramid Network`r`n" }
if ($r -match [regex]::Escape($sectionStart) -and $r -match [regex]::Escape($sectionEnd)) {
  $pattern = [regex]::Escape($sectionStart) + ".*?" + [regex]::Escape($sectionEnd)
Write-Host "[PPN] NOTE: README splice disabled (regex-timeout guard)" -ForegroundColor Yellow; $r = $r
} else {
  $r = $r.TrimEnd() + "`r`n`r`n" + $readmeSection + "`r`n"
}
if (-not $NoReadmeWrite) {
  Write-FileUtf8 $ReadmePath $r
} else {
  Write-Host "[PPN] NOTE: README write skipped (-NoReadmeWrite)" -ForegroundColor DarkCyan
}
# ----------------------------
# Optional TEMP cleanup patch (no $_ expansion)
# ----------------------------
if ($EnableRunnerTempCleanup) {
  if (-not (Test-Path -LiteralPath $RunnerPath)) { throw "Runner missing: $RunnerPath" }
  $rr = Get-Content -LiteralPath $RunnerPath -Raw -Encoding UTF8
  if ($rr -notmatch "PPN TEMP CLEANUP") {
    $cleanup = @(
      ""
      "# ----- PPN TEMP CLEANUP (canonical) -----"
      "try {"
      "  Get-ChildItem -LiteralPath `$env:TEMP -Filter ""ppn_ab_compare_*.py"" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue"
      "  Get-ChildItem -LiteralPath `$env:TEMP -Filter ""ppn_ab_plots_*.py""   -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue"
      "  Write-Host ""✓ PPN TEMP CLEANUP: removed temp python files"" -ForegroundColor DarkGreen"
      "} catch {"
      "  Write-Host ""ℹ PPN TEMP CLEANUP skipped (non-fatal): `$(`$_.Exception.Message)"" -ForegroundColor DarkGray"
      "}"
    ) -join "`r`n"
    $rr = $rr.TrimEnd() + "`r`n" + $cleanup + "`r`n"
    Set-Content -LiteralPath $RunnerPath -Encoding UTF8 -Value $rr
  }
}

Write-Host "`r`n================ DOCS WRITE SUMMARY ================" -ForegroundColor Green
Get-ChildItem -LiteralPath $DocsRoot -File | Select-Object Name, Length, FullName | Format-Table -AutoSize
Write-Host "`r`n✅ PPN DOCS ONE-SHOT COMPLETE" -ForegroundColor Green

if ($false) {
if ($false) {
# ---- PPN: EXPERIMENT REPRODUCIBILITY V1 (BEGIN) ----
# PPN disabled: reproducibility emission moved to ppn_ab_run.ps1
# ---- PPN: EXPERIMENT REPRODUCIBILITY V1 (END) ----
}
}
