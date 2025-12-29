<#
PPN Command Hub

Usage:
  powershell -ExecutionPolicy Bypass -File .\08_AUTOMATION\powershell\ppn.ps1 init-run -Phase PHASE1
  powershell -ExecutionPolicy Bypass -File .\08_AUTOMATION\powershell\ppn.ps1 ingest -ExperimentId PPN-P1-0001 -SourceDir "D:\exports\run1"
  powershell -ExecutionPolicy Bypass -File .\08_AUTOMATION\powershell\ppn.ps1 quicklook -ExperimentId PPN-P1-0001

Commands:
  init-run     Create new experiment ID, run sheet, metadata stub, and folders
  ingest       Copy export files into RAW + generate manifest + hashes
  quicklook    Basic quick-look analysis scaffolding (PSD/spectrogram placeholders)
  where        Prints project root
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true, Position=0)]
  [ValidateSet('init-run','ingest','quicklook','where','resonance')]
  [string]$Command,

  [Parameter()][ValidateSet('PHASE1','PHASE2')][string]$Phase,
  [Parameter()][string]$ExperimentId,
  [Parameter()][string]$SourceDir
)

$ErrorActionPreference = 'Stop'

# Robust project-root discovery:
# Walk upward from this script location until we find README.md at the project root.
$project = $PSScriptRoot
while ($true) {
  if (Test-Path (Join-Path $project "README.md")) { break }
  $parent = Split-Path -Parent $project
  if (-not $parent -or $parent -eq $project) { throw "Could not locate project root (README.md not found in parents)." }
  $project = $parent
}

function Die($msg) { throw $msg }

function Ensure-Dir([string]$p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }

function NowId() {
  # e.g. 20251229-163012
  return (Get-Date -Format 'yyyyMMdd-HHmmss')
}

function NextSeq([string]$phaseCode) {
  # phaseCode: P1 or P2
  $metaDir = Join-Path $project '04_DATA\METADATA'
  Ensure-Dir $metaDir
  $existing = Get-ChildItem -Path $metaDir -Filter "PPN-$phaseCode-*.json" -ErrorAction SilentlyContinue |
              Select-Object -ExpandProperty BaseName
  $max = 0
  foreach ($name in $existing) {
    if ($name -match "PPN-$phaseCode-(\d{4})") {
      $n = [int]$Matches[1]
      if ($n -gt $max) { $max = $n }
    }
  }
  return ($max + 1)
}

function Write-Json([string]$path, [hashtable]$obj) {
  $obj | ConvertTo-Json -Depth 8 | Out-File -FilePath $path -Encoding utf8
}

function Hash-File([string]$path) {
  return (Get-FileHash -Algorithm SHA256 -Path $path).Hash
}

switch ($Command) {

  'where' {
    Write-Host $project
    break
  }

  'init-run' {
    if (-not $Phase) { Die "Phase is required (PHASE1 or PHASE2)." }

    $phaseCode = if ($Phase -eq 'PHASE1') { 'P1' } else { 'P2' }
    $seq = NextSeq $phaseCode
    $ExperimentId = "PPN-$phaseCode-{0:D4}" -f $seq

    # run sheet location
    $runDir = Join-Path $project ("02_EXPERIMENTS\{0}_{1}\RUNS" -f $Phase, $(if ($Phase -eq 'PHASE1') { 'SINGLE_NODE' } else { 'MULTI_NODE' }))
    Ensure-Dir $runDir

    $template = Join-Path $project "02_EXPERIMENTS\TEMPLATES\RUN_SHEET.md"
    $runSheet = Join-Path $runDir "$ExperimentId.md"
    if (Test-Path $runSheet) { Die "Run sheet exists: $runSheet" }

    Copy-Item $template $runSheet

    $header = "# $ExperimentId`n`n(Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))`n`n"
    $body = Get-Content $runSheet -Raw
    $header + $body | Out-File -FilePath $runSheet -Encoding utf8

    # data dirs
    $rawDir = Join-Path $project "04_DATA\RAW\$ExperimentId"
    $procDir = Join-Path $project "04_DATA\PROCESSED\$ExperimentId"
    Ensure-Dir $rawDir
    Ensure-Dir $procDir

    # metadata stub
    $metaDir = Join-Path $project "04_DATA\METADATA"
    Ensure-Dir $metaDir
    $metaPath = Join-Path $metaDir "$ExperimentId.json"

    $meta = @{
      experiment_id   = $ExperimentId
      phase           = $Phase
      created_local   = (Get-Date).ToString('o')
      created_utc     = (Get-Date).ToUniversalTime().ToString('o')
      objective       = ""
      configuration   = @{
        geometry      = ""
        materials     = ""
        water_state   = ""
        drive         = @{ type=""; band_hz="0-150"; notes="" }
        grounding     = ""
        shielding     = ""
      }
      sensors         = @()
      environment     = @{ temp_c=""; humidity=""; notes="" }
      paths           = @{
        run_sheet     = $runSheet
        raw_dir       = $rawDir
        processed_dir = $procDir
      }
      provenance      = @{ operator=""; notes="" }
    }

    if (-not (Test-Path $metaPath)) { Write-Json $metaPath $meta }

    Write-Host "âœ… Created Experiment: $ExperimentId" -ForegroundColor Green
    Write-Host " - Run sheet: $runSheet" -ForegroundColor DarkGray
    Write-Host " - Metadata:  $metaPath" -ForegroundColor DarkGray
    Write-Host " - RAW dir:   $rawDir" -ForegroundColor DarkGray
    Write-Host " - PROC dir:  $procDir" -ForegroundColor DarkGray
    break
  }

  'ingest' {
    if (-not $ExperimentId) { Die "ExperimentId is required." }
    if (-not $SourceDir) { Die "SourceDir is required." }
    if (-not (Test-Path $SourceDir)) { Die "SourceDir not found: $SourceDir" }

    $rawDir = Join-Path $project "04_DATA\RAW\$ExperimentId"
    Ensure-Dir $rawDir

    # Copy everything (preserve structure)
    Copy-Item -Path (Join-Path $SourceDir '*') -Destination $rawDir -Recurse -Force

    # Manifest + hashes
    $files = Get-ChildItem -Path $rawDir -File -Recurse | Sort-Object FullName
    $manifest = @()
    foreach ($f in $files) {
      $rel = $f.FullName.Substring($rawDir.Length).TrimStart('\')
      $manifest += [pscustomobject]@{
        relative_path = $rel
        bytes         = $f.Length
        sha256        = (Hash-File $f.FullName)
        modified_utc  = $f.LastWriteTimeUtc.ToString('o')
      }
    }

    $metaDir = Join-Path $project "04_DATA\METADATA"
    Ensure-Dir $metaDir
    $manifestPath = Join-Path $metaDir "$ExperimentId.manifest.json"
    $manifest | ConvertTo-Json -Depth 6 | Out-File -FilePath $manifestPath -Encoding utf8

    Write-Host "âœ… Ingest complete: $ExperimentId" -ForegroundColor Green
    Write-Host " - RAW dir:      $rawDir" -ForegroundColor DarkGray
    Write-Host " - Manifest:     $manifestPath" -ForegroundColor DarkGray
    Write-Host " - Files copied: $($files.Count)" -ForegroundColor DarkGray
    break
  }

  'quicklook' {
    if (-not $ExperimentId) { Die "ExperimentId is required." }

    $rawDir  = Join-Path $project "04_DATA\RAW\$ExperimentId"
    $outDir  = Join-Path $project "05_ANALYSIS\REPORTS\$ExperimentId"
    Ensure-Dir $outDir

    if (-not (Test-Path $rawDir)) { Die "RAW dir not found: $rawDir" }

    # Locate candidate files (CSV, WAV, JSON)
    $csv = Get-ChildItem -Path $rawDir -Recurse -File -Filter *.csv -ErrorAction SilentlyContinue
    $wav = Get-ChildItem -Path $rawDir -Recurse -File -Filter *.wav -ErrorAction SilentlyContinue
    $json = Get-ChildItem -Path $rawDir -Recurse -File -Filter *.json -ErrorAction SilentlyContinue

    $report = @()
    $report += "# Quicklook Report: $ExperimentId"
    $report += ""
    $report += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $report += ""
    $report += "## RAW Inventory"
    $report += "- CSV:  $($csv.Count)"
    $report += "- WAV:  $($wav.Count)"
    $report += "- JSON: $($json.Count)"
    $report += ""
    if ($csv.Count -gt 0) {
      $report += "### CSV Files"
      foreach ($f in $csv) { $report += "- $($f.FullName)" }
      $report += ""
    }
    if ($wav.Count -gt 0) {
      $report += "### WAV Files"
      foreach ($f in $wav) { $report += "- $($f.FullName)" }
      $report += ""
    }
    if ($json.Count -gt 0) {
      $report += "### JSON Files"
      foreach ($f in $json) { $report += "- $($f.FullName)" }
      $report += ""
    }

    $mdPath = Join-Path $outDir "quicklook.md"
    $report -join "`n" | Out-File -FilePath $mdPath -Encoding utf8

    Write-Host "âœ… Quicklook created: $mdPath" -ForegroundColor Green
    Write-Host "Next: run python analysis once you know sampling rates / column names." -ForegroundColor Yellow
    break
  }

}

