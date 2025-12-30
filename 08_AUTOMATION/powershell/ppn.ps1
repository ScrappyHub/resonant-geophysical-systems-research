[CmdletBinding()]
param(
  [Parameter(Mandatory=$true, Position=0)]
  [ValidateSet('where','status','init-run','ingest','quicklook','resonance','resonance-summary','resonance-plot')]
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

  'docs-index' {
    $idx = Join-Path $project '01_DOCS\00_OVERVIEW\README_INDEX.md'
    if (-not (Test-Path $idx)) { Die "Missing docs index: $idx" }

    Write-Host "✅ Docs index:" -ForegroundColor Green
    Write-Host (" - " + $idx) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "---- BEGIN README_INDEX.md (first 20 lines) ----" -ForegroundColor Cyan
    (Get-Content $idx -TotalCount 20) | ForEach-Object { Write-Host [CmdletBinding()]
param(
  [Parameter(Mandatory=$true, Position=0)]
  [ValidateSet('where','status','init-run','ingest','quicklook','resonance','resonance-summary','resonance-plot')]
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

    Write-Host "✅ Created Experiment: $ExperimentId" -ForegroundColor Green
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

    Write-Host "✅ Ingest complete: $ExperimentId" -ForegroundColor Green
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
    Write-Host "✅ Quicklook created: $mdPath" -ForegroundColor Green
    break
  }

  'resonance' {
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

    Write-Host "✅ Resonance complete: $json" -ForegroundColor Green
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

    Write-Host "✅ Resonance summary: $ExperimentId" -ForegroundColor Green
    Write-Host " - JSON: $json" -ForegroundColor DarkGray
    Write-Host " - CSV:  $csvPath" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Top 10 by EM_RMS:" -ForegroundColor Cyan
    $top | Format-Table drive_hz, em_rms, vib_rms, chamber_rms, peak_em_hz -AutoSize
    break
  }

  'resonance-plot' {
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

    Write-Host "✅ Resonance plots complete: $ExperimentId" -ForegroundColor Green
    Write-Host " - PROC: $dir" -ForegroundColor DarkGray
    Write-Host " - RPT:  $reportDir" -ForegroundColor DarkGray
    break
  }

}
 }
    Write-Host "---- END README_INDEX.md ----" -ForegroundColor Cyan
    break
  }
  'git-hygiene' {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Die "git not found on PATH." }
    Push-Location $project
    try {
      Write-Host "✅ git-hygiene @ " -NoNewline -ForegroundColor Green
      Write-Host (git rev-parse --show-toplevel) -ForegroundColor DarkGray
      Write-Host ""
      git status
      Write-Host ""
      Write-Host "Key .gitignore lines (first match each):" -ForegroundColor Cyan
      $gi = Join-Path $project ".gitignore"
      if (Test-Path $gi) {
        foreach ($p in @("04_DATA/","05_ANALYSIS/","__pycache__/","*.pyc",".vscode/")) {
          $hit = Select-String -Path $gi -SimpleMatch -Pattern $p -ErrorAction SilentlyContinue | Select-Object -First 1
          if ($hit) { Write-Host (" - " + $hit.Line.Trim()) -ForegroundColor DarkGray }
        }
      } else {
        Write-Host "⚠️ .gitignore not found" -ForegroundColor Yellow
      }
      Write-Host ""
      Write-Host "✅ Hygiene check complete." -ForegroundColor Green
    } finally { Pop-Location }
    break
  }
  'run-check' {
    if (-not $ExperimentId) { Die "ExperimentId is required." }

    $proc = Join-Path $project "04_DATA\PROCESSED\$ExperimentId\resonance_engine_v1"
    $rpt  = Join-Path $project "05_ANALYSIS\REPORTS\$ExperimentId\resonance_engine_v1"

    $json = Join-Path $proc "resonance_sweep.json"
    $csv  = Join-Path $proc "resonance_sweep.csv"
    $band = Join-Path $proc "best_band.txt"

    Write-Host "RUN CHECK: $ExperimentId" -ForegroundColor Cyan
    Write-Host (" - PROC: " + $proc) -ForegroundColor DarkGray
    Write-Host (" - RPT:  " + $rpt)  -ForegroundColor DarkGray

    $need = @($json, $csv, $band)
    $missing = @()
    foreach ($p in $need) { if (-not (Test-Path $p)) { $missing += $p } }

    if ($missing.Count -gt 0) {
      Write-Host "❌ Missing expected outputs:" -ForegroundColor Red
      $missing | ForEach-Object { Write-Host (" - " + [CmdletBinding()]
param(
  [Parameter(Mandatory=$true, Position=0)]
  [ValidateSet('where','status','init-run','ingest','quicklook','resonance','resonance-summary','resonance-plot')]
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

    Write-Host "✅ Created Experiment: $ExperimentId" -ForegroundColor Green
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

    Write-Host "✅ Ingest complete: $ExperimentId" -ForegroundColor Green
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
    Write-Host "✅ Quicklook created: $mdPath" -ForegroundColor Green
    break
  }

  'resonance' {
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

    Write-Host "✅ Resonance complete: $json" -ForegroundColor Green
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

    Write-Host "✅ Resonance summary: $ExperimentId" -ForegroundColor Green
    Write-Host " - JSON: $json" -ForegroundColor DarkGray
    Write-Host " - CSV:  $csvPath" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Top 10 by EM_RMS:" -ForegroundColor Cyan
    $top | Format-Table drive_hz, em_rms, vib_rms, chamber_rms, peak_em_hz -AutoSize
    break
  }

  'resonance-plot' {
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

    Write-Host "✅ Resonance plots complete: $ExperimentId" -ForegroundColor Green
    Write-Host " - PROC: $dir" -ForegroundColor DarkGray
    Write-Host " - RPT:  $reportDir" -ForegroundColor DarkGray
    break
  }

}
) -ForegroundColor Yellow }
      Die "Run check failed."
    }

    Write-Host "✅ Found outputs:" -ForegroundColor Green
    foreach ($p in $need) {
      $fi = Get-Item $p
      Write-Host (" - " + $fi.Name + " (" + [Math]::Round($fi.Length/1KB,2) + " KB)") -ForegroundColor DarkGray
    }

    Write-Host "✅ Run check passed: $ExperimentId" -ForegroundColor Green
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

    Write-Host "✅ Created Experiment: $ExperimentId" -ForegroundColor Green
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

    Write-Host "✅ Ingest complete: $ExperimentId" -ForegroundColor Green
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
    Write-Host "✅ Quicklook created: $mdPath" -ForegroundColor Green
    break
  }

  'resonance' {
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

    Write-Host "✅ Resonance complete: $json" -ForegroundColor Green
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

    Write-Host "✅ Resonance summary: $ExperimentId" -ForegroundColor Green
    Write-Host " - JSON: $json" -ForegroundColor DarkGray
    Write-Host " - CSV:  $csvPath" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Top 10 by EM_RMS:" -ForegroundColor Cyan
    $top | Format-Table drive_hz, em_rms, vib_rms, chamber_rms, peak_em_hz -AutoSize
    break
  }

  'resonance-plot' {
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

    Write-Host "✅ Resonance plots complete: $ExperimentId" -ForegroundColor Green
    Write-Host " - PROC: $dir" -ForegroundColor DarkGray
    Write-Host " - RPT:  $reportDir" -ForegroundColor DarkGray
    break
  }

}
