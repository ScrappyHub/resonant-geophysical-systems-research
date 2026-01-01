param(
  [string]$RepoRoot = "M:\Plantery Pyramid Network",
  [switch]$EnableRunnerTempCleanup
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
Write-FileUtf8 $ReadmePath $r

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

# ---- PPN: EXPERIMENT REPRODUCIBILITY V1 (BEGIN) ----
try {
  function Ppn-NormPath([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return $p }
    return [IO.Path]::GetFullPath($p).TrimEnd('\','/')
  }

  function Ppn-GitHead([string]$RepoRoot) {
    try {
      $v = (& git -C $RepoRoot rev-parse HEAD 2>$null)
      if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    } catch {}
    return "<unknown>"
  }

  function Ppn-Req([string]$Name, [object]$Val) {
    if ($null -eq $Val) { throw ("Missing required condition: " + $Name) }
    if ($Val -is [string] -and [string]::IsNullOrWhiteSpace([string]$Val)) { throw ("Missing required condition: " + $Name) }
  }

  function Ppn-IsNaN([double]$d) { return [double]::IsNaN($d) }

  # Must exist by end-of-script (your ab builder already defines these)
  if (-not (Get-Variable -Name p2AB -ErrorAction SilentlyContinue)) { throw "p2AB missing at end-of-script (unexpected)" }
  if (-not (Get-Variable -Name P1  -ErrorAction SilentlyContinue)) { throw "P1 missing at end-of-script (unexpected)" }
  if (-not (Get-Variable -Name P2  -ErrorAction SilentlyContinue)) { throw "P2 missing at end-of-script (unexpected)" }
  if (-not (Get-Variable -Name exportsRoot -ErrorAction SilentlyContinue)) { throw "exportsRoot missing at end-of-script (unexpected)" }
  if (-not (Get-Variable -Name BundleDir -ErrorAction SilentlyContinue)) { throw "BundleDir missing at end-of-script (unexpected)" }
  if (-not (Get-Variable -Name bestBandPath -ErrorAction SilentlyContinue)) { throw "bestBandPath missing at end-of-script (unexpected)" }

  # RepoRoot should exist as a param in your script; fall back to git root if not
  if (-not (Get-Variable -Name RepoRoot -ErrorAction SilentlyContinue)) { $RepoRoot = "M:/Plantery Pyramid Network" }

  # Load condition profile JSON if provided (preferred), else allow direct CLI fields
  $profileObj = $null
  if (-not [string]::IsNullOrWhiteSpace($ConditionsPath)) {
    if (-not (Test-Path -LiteralPath $ConditionsPath)) { throw ("ConditionsPath not found: " + $ConditionsPath) }
    $profileObj = Get-Content -Raw -LiteralPath $ConditionsPath -Encoding UTF8 | ConvertFrom-Json
  }
  elseif (-not [string]::IsNullOrWhiteSpace($ConditionProfile)) {
    $p = Join-Path $RepoRoot ("conditions\profiles\{0}.json" -f $ConditionProfile)
    if (-not (Test-Path -LiteralPath $p)) { throw ("ConditionProfile not found: " + $p) }
    $profileObj = Get-Content -Raw -LiteralPath $p -Encoding UTF8 | ConvertFrom-Json
    $ConditionsPath = $p
  }

  # STRICT MODE: require minimal defensible set (from profile if present, else from CLI fields)
  if ($RequireConditions) {
    if ($profileObj) {
      Ppn-Req "profile" ($profileObj.profile)
      Ppn-Req "environment.type" ($profileObj.environment.type)
      Ppn-Req "mounting" ($profileObj.mounting)
      Ppn-Req "drive_profile" ($profileObj.drive_profile)
      Ppn-Req "sensor_pack" ($profileObj.sensor_pack)
      Ppn-Req "sample_id" ($profileObj.sample_id)
      Ppn-Req "operator" ($profileObj.operator)
      # Key for dry/humid comparisons
      if ($profileObj.environment.type -in @("dry","humid")) {
        Ppn-Req "environment.humidity_rh" ($profileObj.environment.humidity_rh)
        Ppn-Req "environment.temp_c" ($profileObj.environment.temp_c)
      }
    } else {
      Ppn-Req "ConditionProfile/ConditionsPath" $ConditionProfile
      Ppn-Req "Environment" $Environment
      Ppn-Req "Mounting" $Mounting
      Ppn-Req "DriveProfile" $DriveProfile
      Ppn-Req "SensorPack" $SensorPack
      Ppn-Req "SampleId" $SampleId
      if (Ppn-IsNaN $HumidityRH) { throw "Missing required condition: HumidityRH" }
      if (Ppn-IsNaN $TempC) { throw "Missing required condition: TempC" }
    }
  }

  # Resolve effective condition values (profile overrides CLI when present)
  $eff = [ordered]@{
    schema = "PPN_RUN_CONDITIONS_V1"
    run_id = ("PPN_RUN_" + [DateTime]::UtcNow.ToString("yyyyMMdd_HHmmss") + "_" + $P2)
    timestamp_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    git_head = (Ppn-GitHead $RepoRoot)

    P1 = $P1
    P2 = $P2
    exportsRoot = (Ppn-NormPath $exportsRoot)
    BundleDir = (Ppn-NormPath $BundleDir)
    bestBandPath_bundle = (Ppn-NormPath $bestBandPath)
    ab_output_dir = (Ppn-NormPath $p2AB)

    condition_profile = (if ($profileObj) { $profileObj.profile } else { $ConditionProfile })
    conditions_path   = (if (-not [string]::IsNullOrWhiteSpace($ConditionsPath)) { (Ppn-NormPath $ConditionsPath) } else { "" })

    environment = (if ($profileObj) { $profileObj.environment } else {
      [ordered]@{
        type = $Environment
        humidity_rh = (if (Ppn-IsNaN $HumidityRH) { $null } else { $HumidityRH })
        temp_c = (if (Ppn-IsNaN $TempC) { $null } else { $TempC })
        pressure_kpa = (if (Ppn-IsNaN $PressureKPa) { $null } else { $PressureKPa })
      }
    })

    mounting = (if ($profileObj) { $profileObj.mounting } else { $Mounting })
    drive_profile = (if ($profileObj) { $profileObj.drive_profile } else { $DriveProfile })
    sensor_pack = (if ($profileObj) { $profileObj.sensor_pack } else { $SensorPack })
    sample_id = (if ($profileObj) { $profileObj.sample_id } else { $SampleId })
    operator = (if ($profileObj) { $profileObj.operator } else { $Operator })
    notes = (if ($profileObj -and $profileObj.notes) { $profileObj.notes } else { $Notes })

    host = [ordered]@{
      computer = $env:COMPUTERNAME
      user = $env:USERNAME
      os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
      pwsh = $PSVersionTable.PSVersion.ToString()
    }
  }

  $json = ($eff | ConvertTo-Json -Depth 12)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $hash = $sha.ComputeHash($bytes)
    $condSha = ($hash | ForEach-Object { $_.ToString("x2") }) -join ""
  } finally { $sha.Dispose() }

  $condPath = Join-Path $p2AB "RUN_CONDITIONS.json"
  [IO.File]::WriteAllText($condPath, ($json + "
"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host ("[PPN] WROTE RUN_CONDITIONS.json -> " + $condPath) -ForegroundColor DarkGreen

  # Append reproducibility refs into pointer (if present)
  $ptrPath = Join-Path $p2AB "AB_inputs_pointer.txt"
  if (Test-Path -LiteralPath $ptrPath) {
    $append = @(
      ""
      "PPN_REPRODUCIBILITY_V1"
      ("run_id=" + $eff.run_id)
      ("conditions_path=" + (Ppn-NormPath $condPath))
      ("conditions_sha256=" + $condSha)
    ) -join "
"
    Add-Content -LiteralPath $ptrPath -Value ($append + "
") -Encoding UTF8
    Write-Host ("[PPN] Appended reproducibility refs -> " + $ptrPath) -ForegroundColor DarkGreen
  } else {
    Write-Host ("[PPN] NOTE: pointer not found to append reproducibility refs: " + $ptrPath) -ForegroundColor Yellow
  }

} catch {
  throw ("PPN reproducibility layer failed: " + $_.Exception.Message)
}
# ---- PPN: EXPERIMENT REPRODUCIBILITY V1 (END) ----
