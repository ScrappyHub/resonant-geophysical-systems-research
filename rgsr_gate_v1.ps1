param(
  [Parameter(Mandatory=$true)][string]$Root,
  [Parameter(Mandatory=$true)][string]$OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root   = (Resolve-Path -LiteralPath $Root).Path
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# Canonical local copy path for introspector
$pyPath = Join-Path $OutDir "rgsr_gate_v1_introspect.py"

# ==============================
# RGSR: CANONICAL SELF-AUDIT V1
# - must run INSIDE script
# - forbids embedded python writer
# - forbids spawning nested pwsh/powershell
# - forbids exit
# ==============================
$__thisPath = $null
if ($PSCommandPath) { $__thisPath = $PSCommandPath }
elseif ($MyInvocation -and $MyInvocation.MyCommand -and ($MyInvocation.MyCommand.PSObject.Properties.Name -contains "Path")) {
  $__thisPath = $MyInvocation.MyCommand.Path
}
if (-not $__thisPath) { throw "RGSR GATE FAIL: cannot resolve script path for self-audit. Run via & .\rgsr_gate_v1.ps1 (not pasted blocks)." }

$__self = Get-Content -LiteralPath $__thisPath -Raw

# Disallow embedded python-writer pattern
if ($__self -match 'pyLines\s*=\s*@\(') {
  throw "RGSR GATE FAIL: embedded python writer detected (pyLines). Canonical requires repo introspector copy-block."
}

# Canonical introspector source lives in repo root (no embedded python in PS)
$repoPy = Join-Path $PSScriptRoot "rgsr_gate_v1_introspect.py"
if (-not $PSScriptRoot) { throw "RGSR GATE FAIL: PSScriptRoot is empty. Gate must be executed from file, not pasted." }
if (!(Test-Path -LiteralPath $repoPy)) { throw "Missing canonical introspector: $repoPy" }

# Prove copy-block exists in script text (prevents drift)
if ($__self -notmatch [regex]::Escape('$repoPy = Join-Path $PSScriptRoot "rgsr_gate_v1_introspect.py"')) {
  throw "RGSR GATE FAIL: missing canonical repo introspector path line."
}
if ($__self -notmatch [regex]::Escape('Copy-Item -Force -LiteralPath $repoPy -Destination $pyPath')) {
  throw "RGSR GATE FAIL: missing canonical introspector copy-block."
}

# Forbid nested pwsh/powershell spawning + exit (comments ok; strings ignored)
$__lines = $__self -split "`r?`n"
foreach ($ln in $__lines) {
  $t = $ln.TrimStart()
  if (-not $t) { continue }
  if ($t -like "#*") { continue }

  $code = $t
  $code = [regex]::Replace($code, '"([^"\\]|\\.)*"', '""')
  $code = [regex]::Replace($code, "'([^'\\]|\\.)*'", "''")

  if ($code -match '(^|[;\s])(&\s*)?(pwsh|powershell)(\.exe)?(\s|$)') {
    throw "RGSR GATE FAIL: nested pwsh/powershell execution detected. Canonical forbids spawning nested shells."
  }
  if ($code -match 'Start-Process\s+.*\b(pwsh|powershell)(\.exe)?\b') {
    throw "RGSR GATE FAIL: Start-Process pwsh/powershell detected. Canonical forbids spawning nested shells."
  }
  if ($code -match '\bexit\b') {
    throw "RGSR GATE FAIL: exit detected in code. Canonical forbids exit."
  }
}

# ==============================
# CANONICAL: copy introspector + run
# ==============================
Copy-Item -Force -LiteralPath $repoPy -Destination $pyPath

Write-Host "RGSR: Running Gate V1 introspection..."
$txt,$sum,$col = & python.exe -B $pyPath $Root $OutDir

Write-Host ""
Write-Host "RGSR: Reports generated:"
Write-Host " - $txt"
Write-Host " - $sum"
Write-Host " - $col"
Write-Host ""

# ==============================
# RGSR: CANONICAL ENFORCEMENT V1
# - hard invariants on summary fields + strict collisions
# ==============================
function Count-Props($o) {
  if ($null -eq $o) { return 0 }
  return @($o.PSObject.Properties).Count
}

$sumPath = Join-Path $OutDir "rgsr_gate_v1_summary.json"
$colPath = Join-Path $OutDir "rgsr_gate_v1_collisions.json"
$txtPath = Join-Path $OutDir "rgsr_gate_v1_report.txt"

if (!(Test-Path -LiteralPath $sumPath)) { throw "RGSR GATE FAIL: Missing summary: $sumPath" }
if (!(Test-Path -LiteralPath $colPath)) { throw "RGSR GATE FAIL: Missing collisions: $colPath" }
if (!(Test-Path -LiteralPath $txtPath)) { throw "RGSR GATE FAIL: Missing report: $txtPath" }

$summary = Get-Content -LiteralPath $sumPath -Raw | ConvertFrom-Json
$coll    = Get-Content -LiteralPath $colPath -Raw | ConvertFrom-Json

if (!($summary.PSObject.Properties.Name -contains "results_path_nodes_seen")) {
  throw "RGSR GATE FAIL: Non-canonical introspector output (missing results_path_nodes_seen)."
}
if (!($summary.PSObject.Properties.Name -contains "configs_detected")) {
  throw "RGSR GATE FAIL: Non-canonical introspector output (missing configs_detected)."
}

$failCount = @($summary.failures).Count
$frames    = [int]$summary.frames_detected
if ($failCount -gt 0) { throw "RGSR GATE FAIL: JSON failures=$failCount (see $sumPath)" }
if ($frames -le 0)    { throw "RGSR GATE FAIL: frames_detected=$frames (see $sumPath)" }

# collisions (strict only = fatal)
$strict = $null
if ($coll.PSObject.Properties.Name -contains "strict_unique_id_collisions") {
  $strict = $coll.strict_unique_id_collisions
} else {
  $strict = $coll
}

$strictBad = 0
$strictBad += Count-Props $strict.material_profile_ids
$strictBad += Count-Props $strict.layer_stack_ids
$strictBad += Count-Props $strict.subsurface_domain_ids
if ($strictBad -gt 0) { throw "RGSR GATE FAIL: STRICT unique ID collisions detected ($strictBad) (see $colPath)" }

# grouping collisions are informational
if ($coll.PSObject.Properties.Name -contains "grouping_id_collisions") {
  $grp = $coll.grouping_id_collisions
  $warns = @()
  foreach ($k in @("experiment_id","sample_id","phase1_experiment_id","phase2_experiment_id")) {
    if ($grp.PSObject.Properties.Name -contains $k) {
      $c = Count-Props ($grp.$k)
      if ($c -gt 0) { $warns += "$k=$c" }
    }
  }
  if ($warns.Count -gt 0) { Write-Warning ("RGSR GATE WARN (expected grouping repeats): " + ($warns -join ", ")) }
}

Write-Host ""
Write-Host ("RGSR GATE PASS: failures=0; frames_detected=" + $frames + "; strict_unique_id_collisions=0")
Write-Host ("Report:  " + $txtPath)
Write-Host ("Summary: " + $sumPath)
Write-Host ("Coll:    " + $colPath)

return 0
