param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [Parameter(Mandatory)][string]$P2,

  # Reproducibility controls
  [switch]$RequireConditions,
  [string]$ConditionProfile = "",         # e.g. DRY_BASELINE_V1
  [string]$ConditionsPath = "",           # optional direct json path
  [string]$Operator = "",
  [string]$Notes = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$Msg) { throw $Msg }

function NormPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  return [IO.Path]::GetFullPath($p).TrimEnd('\','/')
}

function Sha256Text([string]$s) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $b = [System.Text.Encoding]::UTF8.GetBytes($s)
    ($sha.ComputeHash($b) | ForEach-Object { $_.ToString("x2") }) -join ""
  } finally { $sha.Dispose() }
}

function Sha256File([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $fs = [IO.File]::OpenRead($path)
    try {
      ($sha.ComputeHash($fs) | ForEach-Object { $_.ToString("x2") }) -join ""
    } finally { $fs.Dispose() }
  } finally { $sha.Dispose() }
}

# --- Resolve core script (AB packet builder) ---
$core = Join-Path $RepoRoot "08_AUTOMATION\powershell\ppn_ab_packet.ps1"
if (-not (Test-Path -LiteralPath $core)) { Fail "Missing core script: $core" }

# --- AB output dir is deterministic by convention ---
$abDir = Join-Path $RepoRoot ("05_ANALYSIS\REPORTS\{0}\_AB_COMPARE" -f $P2)

# --- Load condition profile (optional; required in strict mode) ---
$profileObj = $null
$resolvedProfilePath = ""

if (-not [string]::IsNullOrWhiteSpace($ConditionsPath)) {
  $resolvedProfilePath = $ConditionsPath
} elseif (-not [string]::IsNullOrWhiteSpace($ConditionProfile)) {
  $resolvedProfilePath = Join-Path $RepoRoot ("conditions\profiles\{0}.json" -f $ConditionProfile)
}

if (-not [string]::IsNullOrWhiteSpace($resolvedProfilePath)) {
  if (-not (Test-Path -LiteralPath $resolvedProfilePath)) { Fail "Conditions file not found: $resolvedProfilePath" }
  $profileObj = Get-Content -Raw -LiteralPath $resolvedProfilePath -Encoding UTF8 | ConvertFrom-Json
}

if ($RequireConditions) {
  if (-not $profileObj) { Fail "RequireConditions set but no ConditionProfile/ConditionsPath provided." }
  if (-not $profileObj.profile)       { Fail "Condition profile JSON missing required field: profile" }
  if (-not $profileObj.environment)   { Fail "Condition profile JSON missing required field: environment" }
  if (-not $profileObj.mounting)      { Fail "Condition profile JSON missing required field: mounting" }
  if (-not $profileObj.drive_profile) { Fail "Condition profile JSON missing required field: drive_profile" }
  if (-not $profileObj.sensor_pack)   { Fail "Condition profile JSON missing required field: sensor_pack" }
  if (-not $profileObj.sample_id)     { Fail "Condition profile JSON missing required field: sample_id" }
}

# --- Execute core AB packet builder first ---
Write-Host ("[PPN] RUN core AB builder: P2=" + $P2) -ForegroundColor Cyan
pwsh -NoProfile -ExecutionPolicy Bypass -File $core -RepoRoot $RepoRoot -P2 $P2
if ($LASTEXITCODE -ne 0) { Fail "Core AB builder failed (exit=$LASTEXITCODE)" }

if (-not (Test-Path -LiteralPath $abDir)) { Fail "AB dir not found after run: $abDir" }

# --- Build RUN_CONDITIONS.json (schema-stable) ---
$gitHead = ""
try { $gitHead = (git -C $RepoRoot rev-parse HEAD).Trim() } catch {}
if ([string]::IsNullOrWhiteSpace($gitHead)) { $gitHead = "<unknown>" }

$runUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$runId  = ("PPN_RUN_{0}_{1}" -f ([DateTime]::UtcNow.ToString("yyyyMMdd_HHmmss")), $P2)

$condProfileName = ""
if ($profileObj -and $profileObj.profile) { $condProfileName = [string]$profileObj.profile }
else { $condProfileName = $ConditionProfile }

$condPathResolved = ""
if (-not [string]::IsNullOrWhiteSpace($resolvedProfilePath)) { $condPathResolved = NormPath $resolvedProfilePath }

$conditions = [ordered]@{
  schema        = "PPN_RUN_CONDITIONS_V1"
  run_id        = $runId
  timestamp_utc = $runUtc
  git_head      = $gitHead

  RepoRoot      = (NormPath $RepoRoot)
  P2            = $P2
  ab_output_dir = (NormPath $abDir)

  condition_profile = $condProfileName
  conditions_path   = $condPathResolved
  profile           = $profileObj

  operator     = $Operator
  notes        = $Notes

  host = [ordered]@{
    computer = $env:COMPUTERNAME
    user     = $env:USERNAME
    os       = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    pwsh     = $PSVersionTable.PSVersion.ToString()
  }
}

$json = ($conditions | ConvertTo-Json -Depth 30)
$condSha = (Sha256Text $json)

$condOutPath = Join-Path $abDir "RUN_CONDITIONS.json"
[IO.File]::WriteAllText($condOutPath, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("[PPN] WROTE RUN_CONDITIONS.json -> " + $condOutPath) -ForegroundColor DarkGreen
Write-Host ("[PPN] CONDITIONS_SHA256 -> " + $condSha) -ForegroundColor DarkGreen

# --- Write SHA256SUMS for key artifacts ---
$artifacts = @(
  "AB_compare_P1_vs_P2.csv",
  "AB_in_band_summary.txt",
  "AB_inputs_pointer.txt",
  "RUN_CONDITIONS.json",
  "README_HANDOFF.md",
  "delta_em_rms_in_band.png",
  "delta_em_rms_vs_drive_hz.png",
  "delta_vib_rms_vs_drive_hz.png",
  "delta_chamber_rms_vs_drive_hz.png"
)

$sumLines = New-Object System.Collections.Generic.List[string]
foreach ($a in $artifacts) {
  $p = Join-Path $abDir $a
  if (Test-Path -LiteralPath $p) {
    $h = Sha256File $p
    if ($h) { $sumLines.Add(("{0}  {1}" -f $h, $a)) }
  }
}

$sumPath = Join-Path $abDir "SHA256SUMS.txt"
[IO.File]::WriteAllText($sumPath, ($sumLines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("[PPN] WROTE SHA256SUMS.txt -> " + $sumPath) -ForegroundColor DarkGreen

# --- Append reproducibility footer to pointer (non-destructive) ---
$ptrPath = Join-Path $abDir "AB_inputs_pointer.txt"
if (Test-Path -LiteralPath $ptrPath) {
  $footer = @(
    ""
    "PPN_REPRODUCIBILITY_V1"
    ("run_id=" + $runId)
    ("conditions_path=" + (NormPath $condOutPath))
    ("conditions_sha256=" + $condSha)
    ("sha256sums_path=" + (NormPath $sumPath))
  ) -join "`r`n"

  Add-Content -LiteralPath $ptrPath -Encoding UTF8 -Value ($footer + "`r`n")
  Write-Host ("[PPN] Appended reproducibility footer -> " + $ptrPath) -ForegroundColor DarkGreen
} else {
  Write-Host ("[PPN] NOTE: pointer not found to append footer: " + $ptrPath) -ForegroundColor Yellow
}

Write-Host ("✅ PPN RUN COMPLETE -> " + $abDir) -ForegroundColor Green