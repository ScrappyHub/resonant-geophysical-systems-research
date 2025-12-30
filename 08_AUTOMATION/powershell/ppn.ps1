[CmdletBinding()]
param(
  [Parameter(Mandatory=$true, Position=0)]
  [ValidateSet('where','status','init-run','ingest','quicklook','resonance','resonance-summary','resonance-plot','docs-index','git-hygiene','run-check','help','bootstrap','ingest-validate')]
  [string]$Command,

  [Parameter()][ValidateSet('PHASE1','PHASE2')][string]$Phase,
  [Parameter()][string]$ExperimentId,
  [Parameter()][string]$SourceDir
)

$ErrorActionPreference = 'Stop'

# Robust project-root discovery: walk up until README.md exists
$project = $PSScriptRoot
while ($true) {
  if (Test-Path (Join-Path $project "README.md")) { break }
  $parent = Split-Path -Parent $project
  if (-not $parent -or $parent -eq $project) { throw "Could not locate project root (README.md not found in parents)." }
  $project = $parent
}

function Die($msg) { throw $msg }
function Ensure-Dir([string]$p) { if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }
function Write-Json([string]$path, [hashtable]$obj) { $obj | ConvertTo-Json -Depth 10 | Out-File -FilePath $path -Encoding utf8 }
function Hash-File([string]$path) { return (Get-FileHash -Algorithm SHA256 -Path $path).Hash }
function Get-PythonExe {
  # Prefer 'py' launcher when available (Windows)
  if (Get-Command py -ErrorAction SilentlyContinue) { return "py" }
  if (Get-Command python -ErrorAction SilentlyContinue) { return "python" }
  Die "Python not found on PATH."
}

function Ensure-Bootstrap {
  # Avoid doing pip install -e every single run.
  # Marker is written into 07_SOFTWARE/python/.ppn_bootstrap_ok
  from __future__ import annotations
import argparse
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt

def save_curve(df: pd.DataFrame, x: str, y: str, out: Path, title: str):
    plt.figure()
    plt.plot(df[x], df[y])
    plt.xlabel(x)
    plt.ylabel(y)
    plt.title(title)
    plt.grid(True, which="both", linestyle=":")
    plt.tight_layout()
    plt.savefig(out, dpi=150)
    plt.close()

def estimate_band(df: pd.DataFrame, x: str, y: str):
    # "3 dB-ish" bandwidth on amplitude proxy: threshold = peak / sqrt(2)
    peak_idx = df[y].idxmax()
    peak_x = float(df.loc[peak_idx, x])
    peak_y = float(df.loc[peak_idx, y])
    thr = peak_y / (2 ** 0.5)

    left = df[df[x] <= peak_x]
    right = df[df[x] >= peak_x]

    left_cross = left[left[y] < thr].tail(1)
    right_cross = right[right[y] < thr].head(1)

    f_lo = float(left_cross[x].values[0]) if len(left_cross) else float(left[x].min())
    f_hi = float(right_cross[x].values[0]) if len(right_cross) else float(right[x].max())

    return peak_x, peak_y, f_lo, f_hi

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()

    csv = Path(args.csv)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    df = pd.read_csv(csv)
    df = df.sort_values("drive_hz").reset_index(drop=True)

    # Plots
    save_curve(df, "drive_hz", "em_rms", outdir / "em_rms_vs_drive_hz.png", "EM_RMS vs drive_hz")
    save_curve(df, "drive_hz", "vib_rms", outdir / "vib_rms_vs_drive_hz.png", "VIB_RMS vs drive_hz")
    save_curve(df, "drive_hz", "chamber_rms", outdir / "chamber_rms_vs_drive_hz.png", "CHAMBER_RMS vs drive_hz")

    # Best band (using em_rms)
    peak_x, peak_y, f_lo, f_hi = estimate_band(df, "drive_hz", "em_rms")
    txt = outdir / "best_band.txt"
    txt.write_text(
        f"peak_drive_hz={peak_x}\n"
        f"peak_em_rms={peak_y}\n"
        f"band_lo_hz={f_lo}\n"
        f"band_hi_hz={f_hi}\n",
        encoding="utf-8"
    )

    print(f"Wrote plots + best_band.txt to: {outdir}")

if __name__ == "__main__":
    main() = Get-PythonExe
   = Join-Path M:\Plantery Pyramid Network "07_SOFTWARE\python"
    = Join-Path  ".ppn_bootstrap_ok"

  if (Test-Path ) { return }

  Write-Host "OK Bootstrapping ppn (pip -e)..." -ForegroundColor Cyan
  & from __future__ import annotations
import argparse
from pathlib import Path

import pandas as pd
import matplotlib.pyplot as plt

def save_curve(df: pd.DataFrame, x: str, y: str, out: Path, title: str):
    plt.figure()
    plt.plot(df[x], df[y])
    plt.xlabel(x)
    plt.ylabel(y)
    plt.title(title)
    plt.grid(True, which="both", linestyle=":")
    plt.tight_layout()
    plt.savefig(out, dpi=150)
    plt.close()

def estimate_band(df: pd.DataFrame, x: str, y: str):
    # "3 dB-ish" bandwidth on amplitude proxy: threshold = peak / sqrt(2)
    peak_idx = df[y].idxmax()
    peak_x = float(df.loc[peak_idx, x])
    peak_y = float(df.loc[peak_idx, y])
    thr = peak_y / (2 ** 0.5)

    left = df[df[x] <= peak_x]
    right = df[df[x] >= peak_x]

    left_cross = left[left[y] < thr].tail(1)
    right_cross = right[right[y] < thr].head(1)

    f_lo = float(left_cross[x].values[0]) if len(left_cross) else float(left[x].min())
    f_hi = float(right_cross[x].values[0]) if len(right_cross) else float(right[x].max())

    return peak_x, peak_y, f_lo, f_hi

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--outdir", required=True)
    args = ap.parse_args()

    csv = Path(args.csv)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    df = pd.read_csv(csv)
    df = df.sort_values("drive_hz").reset_index(drop=True)

    # Plots
    save_curve(df, "drive_hz", "em_rms", outdir / "em_rms_vs_drive_hz.png", "EM_RMS vs drive_hz")
    save_curve(df, "drive_hz", "vib_rms", outdir / "vib_rms_vs_drive_hz.png", "VIB_RMS vs drive_hz")
    save_curve(df, "drive_hz", "chamber_rms", outdir / "chamber_rms_vs_drive_hz.png", "CHAMBER_RMS vs drive_hz")

    # Best band (using em_rms)
    peak_x, peak_y, f_lo, f_hi = estimate_band(df, "drive_hz", "em_rms")
    txt = outdir / "best_band.txt"
    txt.write_text(
        f"peak_drive_hz={peak_x}\n"
        f"peak_em_rms={peak_y}\n"
        f"band_lo_hz={f_lo}\n"
        f"band_hi_hz={f_hi}\n",
        encoding="utf-8"
    )

    print(f"Wrote plots + best_band.txt to: {outdir}")

if __name__ == "__main__":
    main() -m pip install -e  | Out-Host
  if (0 -ne 0) { Die "pip install -e failed." }

  "OK 2025-12-29T21:44:35.8837302-05:00" | Out-File -FilePath  -Encoding utf8
  Write-Host "OK Bootstrap complete." -ForegroundColor Green
}

function Find-PrimaryCsv([string]) {
   = Get-ChildItem -Path  -File -Recurse -Filter *.csv -ErrorAction SilentlyContinue
  if (-not  -or .Count -eq 0) { return  }

  # Prefer common names
   = @("signal.csv","sample_signal.csv","primary_signal.csv")
  foreach (99_ARCHIVE in ) {
     =  | Where-Object { .Name -ieq 99_ARCHIVE } | Select-Object -First 1
    if () { return .FullName }
  }

  # Otherwise: smallest heuristic = pick the largest csv (often the primary)
   =  | Sort-Object Length -Descending | Select-Object -First 1
  return .FullName
}

function Validate-RawDrop([string]PPN-P1-0001) {
  if (-not PPN-P1-0001) { Die "ExperimentId is required." }
   = Join-Path M:\Plantery Pyramid Network "04_DATA\RAW\PPN-P1-0001"
  if (-not (Test-Path )) { Die "RAW dir missing: " }

  # Planetary Pyramid Network (PPN)

This workspace is a structured research + build environment for testing the **Planetary Resonance Grid Hypothesis**
using falsifiable experiments (Phase 1 / Phase 2), sensors, signal processing, and (optional) simulation.

## Folder Map
- 01_DOCS: Theory, methods, references
- 02_EXPERIMENTS: Test plans and run logs
- 03_HARDWARE: BOM, sensor specs, build logs
- 04_DATA: Raw + processed datasets and metadata
- 05_ANALYSIS: Notebooks, reports, figures
- 06_SIMULATION: Optional multiphysics work
- 07_SOFTWARE: Python tooling + scripts
- 08_AUTOMATION: PowerShell pipelines (data ingest, run book helpers)

## Golden Rules
1) Everything must be testable, measurable, and logged.
2) Every experiment has: plan â†’ instrumentation â†’ run â†’ analysis â†’ report.
3) Raw data is immutable (never overwrite RAW).
4) Reports reference exact dataset + commit hash (if using git).

## Docs
See:  1_DOCS/00_OVERVIEW/README_INDEX.md
 = Join-Path  "README_SOURCE.txt"
  if (-not (Test-Path # Planetary Pyramid Network (PPN)

This workspace is a structured research + build environment for testing the **Planetary Resonance Grid Hypothesis**
using falsifiable experiments (Phase 1 / Phase 2), sensors, signal processing, and (optional) simulation.

## Folder Map
- 01_DOCS: Theory, methods, references
- 02_EXPERIMENTS: Test plans and run logs
- 03_HARDWARE: BOM, sensor specs, build logs
- 04_DATA: Raw + processed datasets and metadata
- 05_ANALYSIS: Notebooks, reports, figures
- 06_SIMULATION: Optional multiphysics work
- 07_SOFTWARE: Python tooling + scripts
- 08_AUTOMATION: PowerShell pipelines (data ingest, run book helpers)

## Golden Rules
1) Everything must be testable, measurable, and logged.
2) Every experiment has: plan â†’ instrumentation â†’ run â†’ analysis â†’ report.
3) Raw data is immutable (never overwrite RAW).
4) Reports reference exact dataset + commit hash (if using git).

## Docs
See:  1_DOCS/00_OVERVIEW/README_INDEX.md
)) { Die "Missing README_SOURCE.txt in RAW: " }

   = Find-PrimaryCsv 
  if (-not ) { Die "No CSV found in RAW: " }

  # Validate required columns (case-insensitive): t, value
   = (Get-Content -Path  -TotalCount 1)
  if (-not ) { Die "CSV appears empty: " }

   = .Split(",") | ForEach-Object { .Trim().Trim('"') }
   =  | Where-Object {  -ieq "t" } | Select-Object -First 1
   =  | Where-Object {  -ieq "value" } | Select-Object -First 1
  if (-not  -or -not ) {
    Die ("CSV missing required columns t,value. Found: " + ( -join ", ") + " @ " + )
  }

  return [pscustomobject]@{
    raw_dir      = 
    readme       = # Planetary Pyramid Network (PPN)

This workspace is a structured research + build environment for testing the **Planetary Resonance Grid Hypothesis**
using falsifiable experiments (Phase 1 / Phase 2), sensors, signal processing, and (optional) simulation.

## Folder Map
- 01_DOCS: Theory, methods, references
- 02_EXPERIMENTS: Test plans and run logs
- 03_HARDWARE: BOM, sensor specs, build logs
- 04_DATA: Raw + processed datasets and metadata
- 05_ANALYSIS: Notebooks, reports, figures
- 06_SIMULATION: Optional multiphysics work
- 07_SOFTWARE: Python tooling + scripts
- 08_AUTOMATION: PowerShell pipelines (data ingest, run book helpers)

## Golden Rules
1) Everything must be testable, measurable, and logged.
2) Every experiment has: plan â†’ instrumentation â†’ run â†’ analysis â†’ report.
3) Raw data is immutable (never overwrite RAW).
4) Reports reference exact dataset + commit hash (if using git).

## Docs
See:  1_DOCS/00_OVERVIEW/README_INDEX.md

    primary_csv  = 
  }
}


function NextSeq([string]$phaseCode) {
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

switch ($Command) {
  'help' {
    Write-Host 'PPN Commands:' -ForegroundColor Cyan
    Write-Host ' - where' -ForegroundColor DarkGray
    Write-Host ' - status -ExperimentId <ID>' -ForegroundColor DarkGray
    Write-Host ' - init-run -Phase PHASE1|PHASE2' -ForegroundColor DarkGray
    Write-Host ' - ingest -ExperimentId <ID> -SourceDir <PATH>' -ForegroundColor DarkGray
    Write-Host ' - ingest-validate -ExperimentId <ID>' -ForegroundColor DarkGray
    Write-Host ' - bootstrap (pip install -e once; creates marker)' -ForegroundColor DarkGray
    Write-Host ' - quicklook -ExperimentId <ID>' -ForegroundColor DarkGray
    Write-Host ' - resonance -ExperimentId <ID>' -ForegroundColor DarkGray
    Write-Host ' - resonance-summary -ExperimentId <ID>' -ForegroundColor DarkGray
    Write-Host ' - resonance-plot -ExperimentId <ID>' -ForegroundColor DarkGray
    Write-Host ' - run-check -ExperimentId <ID>' -ForegroundColor DarkGray
    Write-Host ' - docs-index / git-hygiene' -ForegroundColor DarkGray
    break
  }

  'bootstrap' {
    Ensure-Bootstrap
    break
  }

  'ingest-validate' {
     = Validate-RawDrop PPN-P1-0001
    Write-Host ('OK Ingest validated: ' + PPN-P1-0001) -ForegroundColor Green
    Write-Host (' - RAW:    ' + .raw_dir) -ForegroundColor DarkGray
    Write-Host (' - README: ' + .readme) -ForegroundColor DarkGray
    Write-Host (' - CSV:    ' + .primary_csv) -ForegroundColor DarkGray
    break
  }

  'docs-index' {
    $idx = Join-Path $project '01_DOCS\00_OVERVIEW\README_INDEX.md'
    if (-not (Test-Path $idx)) { Die ('Missing docs index: ' + $idx) }
    Write-Host 'OK Docs index:' -ForegroundColor Green
    Write-Host (' - ' + $idx) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '---- BEGIN README_INDEX.md (first 20 lines) ----' -ForegroundColor Cyan
    Get-Content -Path $idx -TotalCount 20 | ForEach-Object { Write-Host $_ }
    Write-Host '---- END README_INDEX.md ----' -ForegroundColor Cyan
    break
  }

  'git-hygiene' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die 'git not found on PATH.' }
    Push-Location $project
    try {
      Write-Host 'OK git-hygiene @ ' -NoNewline -ForegroundColor Green
      Write-Host (git rev-parse --show-toplevel) -ForegroundColor DarkGray
      Write-Host ''
      git status
      Write-Host ''
      Write-Host 'Key .gitignore lines (first match each):' -ForegroundColor Cyan
      $gi = Join-Path $project '.gitignore'
      if (Test-Path $gi) {
        foreach ($p in @('04_DATA/','05_ANALYSIS/','__pycache__/','*.pyc','.vscode/')) {
          $hit = Select-String -Path $gi -SimpleMatch -Pattern $p -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($hit) { Write-Host (' - ' + $hit.Line.Trim()) -ForegroundColor DarkGray }
        }
      } else {
        Write-Host 'WARN .gitignore not found' -ForegroundColor Yellow
      }
      Write-Host ''
      Write-Host 'OK Hygiene check complete.' -ForegroundColor Green
    } finally { Pop-Location }
    break
  }

  'run-check' {
    if (-not $ExperimentId) { Die 'ExperimentId is required.' }
    $proc = Join-Path $project ('04_DATA\PROCESSED\' + $ExperimentId + '\resonance_engine_v1')
    $rpt  = Join-Path $project ('05_ANALYSIS\REPORTS\' + $ExperimentId + '\resonance_engine_v1')
    $json = Join-Path $proc 'resonance_sweep.json'
    $csv  = Join-Path $proc 'resonance_sweep.csv'
    $band = Join-Path $proc 'best_band.txt'
    Write-Host ('RUN CHECK: ' + $ExperimentId) -ForegroundColor Cyan
    Write-Host (' - PROC: ' + $proc) -ForegroundColor DarkGray
    Write-Host (' - RPT:  ' + $rpt)  -ForegroundColor DarkGray
    $need = @($json, $csv, $band)
    $missing = @()
    foreach ($p in $need) { if (-not (Test-Path $p)) { $missing += $p } }
    if ($missing.Count -gt 0) {
      Write-Host 'MISSING expected outputs:' -ForegroundColor Red
      $missing | ForEach-Object { Write-Host (' - ' + $_) -ForegroundColor Yellow }
      Die 'Run check failed.'
    }
    Write-Host 'OK Found outputs:' -ForegroundColor Green
    foreach ($p in $need) {
      $fi = Get-Item $p
      Write-Host (' - ' + $fi.Name + ' (' + [Math]::Round($fi.Length/1KB,2) + ' KB)') -ForegroundColor DarkGray
    }
    Write-Host ('OK Run check passed: ' + $ExperimentId) -ForegroundColor Green
    break
  }


  'where' {
    Write-Host $project
    break
  }

  'status' {
    if (-not $ExperimentId) { Die "ExperimentId is required." }

    $raw  = Join-Path $project "04_DATA\RAW\$ExperimentId"
    $proc = Join-Path $project "04_DATA\PROCESSED\$ExperimentId"
    $rep  = Join-Path $project "05_ANALYSIS\REPORTS\$ExperimentId"

    Write-Host "PPN Status: $ExperimentId" -ForegroundColor Cyan
    Write-Host " - RAW:  $raw"  -ForegroundColor DarkGray
    Write-Host " - PROC: $proc" -ForegroundColor DarkGray
    Write-Host " - RPT:  $rep"  -ForegroundColor DarkGray
    break
  }

  'init-run' {
    if (-not $Phase) { Die "Phase is required (PHASE1 or PHASE2)." }

    $phaseCode = if ($Phase -eq 'PHASE1') { 'P1' } else { 'P2' }
    $seq = NextSeq $phaseCode
    $ExperimentId = "PPN-$phaseCode-{0:D4}" -f $seq

    $runDir = Join-Path $project ("02_EXPERIMENTS\{0}_{1}\RUNS" -f $Phase, $(if ($Phase -eq 'PHASE1') { 'SINGLE_NODE' } else { 'MULTI_NODE' }))
    Ensure-Dir $runDir

    $template = Join-Path $project "02_EXPERIMENTS\TEMPLATES\RUN_SHEET.md"
    if (-not (Test-Path $template)) { Die "Missing template: $template" }

    $runSheet = Join-Path $runDir "$ExperimentId.md"
    Copy-Item $template $runSheet -Force

    $rawDir = Join-Path $project "04_DATA\RAW\$ExperimentId"
    $procDir = Join-Path $project "04_DATA\PROCESSED\$ExperimentId"
    Ensure-Dir $rawDir
    Ensure-Dir $procDir

    $metaDir = Join-Path $project "04_DATA\METADATA"
    Ensure-Dir $metaDir
    $metaPath = Join-Path $metaDir "$ExperimentId.json"

    if (-not (Test-Path $metaPath)) {
      $meta = @{
        experiment_id   = $ExperimentId
        phase           = $Phase
        created_local   = (Get-Date).ToString('o')
        created_utc     = (Get-Date).ToUniversalTime().ToString('o')
        paths           = @{ run_sheet=$runSheet; raw_dir=$rawDir; processed_dir=$procDir }
      }
      Write-Json $metaPath $meta
    }

    Write-Host "OK Created Experiment: $ExperimentId" -ForegroundColor Green
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

    Copy-Item -Path (Join-Path $SourceDir '*') -Destination $rawDir -Recurse -Force

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

    Write-Host "OK Ingest complete: $ExperimentId" -ForegroundColor Green
    Write-Host " - RAW dir:      $rawDir" -ForegroundColor DarkGray
    Write-Host " - Manifest:     $manifestPath" -ForegroundColor DarkGray
    break
  }

  'quicklook' {
    if (-not $ExperimentId) { Die "ExperimentId is required." }
    $rawDir  = Join-Path $project "04_DATA\RAW\$ExperimentId"
    if (-not (Test-Path $rawDir)) { Die "RAW dir not found: $rawDir" }
    $outDir  = Join-Path $project "05_ANALYSIS\REPORTS\$ExperimentId"
    Ensure-Dir $outDir
    $mdPath = Join-Path $outDir "quicklook.md"
    "Quicklook: $ExperimentId`nRAW: $rawDir`nGenerated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" | Out-File -FilePath $mdPath -Encoding utf8
    Write-Host "OK Quicklook created: $mdPath" -ForegroundColor Green
    break
  }

  'resonance' {
    
    Ensure-Bootstrap
if (-not $ExperimentId) { Die "ExperimentId is required." }

    $out1 = Join-Path $project "04_DATA\PROCESSED\$ExperimentId\resonance_engine_v1"
    Ensure-Dir $out1

    $py = Join-Path $project "07_SOFTWARE\python"
    $script = Join-Path $py "scripts\run_resonance_engine.py"
    if (-not (Test-Path $script)) { Die "Missing python script: $script" }

    if (Get-Command py -ErrorAction SilentlyContinue) {
      & py -m pip install -e $py
      & py $script --out $out1
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
      & python -m pip install -e $py
      & python $script --out $out1
    } else {
      Die "Python not found (need 'py' launcher or 'python' on PATH)."
    }

    $json = Join-Path $out1 "resonance_sweep.json"
    if (-not (Test-Path $json)) { Die "Expected output missing: $json" }

    Write-Host "OK Resonance complete: $json" -ForegroundColor Green
    break
  }

  'resonance-summary' {
    if (-not $ExperimentId) { Die "ExperimentId is required." }

    $dir = Join-Path $project "04_DATA\PROCESSED\$ExperimentId\resonance_engine_v1"
    $json = Join-Path $dir "resonance_sweep.json"
    if (-not (Test-Path $json)) { Die "Missing: $json (run: resonance first)" }

    $obj = Get-Content $json -Raw | ConvertFrom-Json

    $csvPath = Join-Path $dir "resonance_sweep.csv"
    $obj.results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvPath

    $top = $obj.results | Sort-Object em_rms -Descending | Select-Object -First 10

    Write-Host "OK Resonance summary: $ExperimentId" -ForegroundColor Green
    Write-Host " - JSON: $json" -ForegroundColor DarkGray
    Write-Host " - CSV:  $csvPath" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Top 10 by EM_RMS:" -ForegroundColor Cyan
    $top | Format-Table drive_hz, em_rms, vib_rms, chamber_rms, peak_em_hz -AutoSize
    break
  }

  'resonance-plot' {
    
    Ensure-Bootstrap
if (-not $ExperimentId) { Die "ExperimentId is required." }

    $dir = Join-Path $project "04_DATA\PROCESSED\$ExperimentId\resonance_engine_v1"
    $csv = Join-Path $dir "resonance_sweep.csv"
    if (-not (Test-Path $csv)) { Die "Missing: $csv (run: resonance-summary first)" }

    $reportDir = Join-Path $project "05_ANALYSIS\REPORTS\$ExperimentId\resonance_engine_v1"
    Ensure-Dir $reportDir

    $py = Join-Path $project "07_SOFTWARE\python"
    $script = Join-Path $py "scripts\plot_resonance_sweep.py"
    if (-not (Test-Path $script)) { Die "Missing python script: $script" }

    if (Get-Command py -ErrorAction SilentlyContinue) {
      & py -m pip install -e $py
      & py $script --csv $csv --outdir $dir
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
      & python -m pip install -e $py
      & python $script --csv $csv --outdir $dir
    } else {
      Die "Python not found (need 'py' launcher or 'python' on PATH)."
    }

    # Copy outputs into reports folder
    Get-ChildItem -Path $dir -Filter *.png -File -ErrorAction SilentlyContinue | ForEach-Object {
      Copy-Item -Path $_.FullName -Destination $reportDir -Force
    }

    $band = Join-Path $dir "best_band.txt"
    if (Test-Path $band) { Copy-Item -Path $band -Destination $reportDir -Force }

    Write-Host "OK Resonance plots complete: $ExperimentId" -ForegroundColor Green
    Write-Host " - PROC: $dir" -ForegroundColor DarkGray
    Write-Host " - RPT:  $reportDir" -ForegroundColor DarkGray
    break
  }

}
