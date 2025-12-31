# ============================================================
# PPN: CANONICAL A/B PACKET BUILDER (P1 vs any P2)
#
# Creates: 05_ANALYSIS\REPORTS\<P2>\_AB_COMPARE\
#   - AB_compare_P1_vs_P2.csv
#   - AB_in_band_summary.txt
#   - AB_inputs_pointer.txt
#   - delta_* plots
#   - README_HANDOFF.md
#   - SHA256SUMS.txt (+ verification output)
#
# Usage:
#   & "M:\Plantery Pyramid Network\08_AUTOMATION\powershell\ppn_ab_packet.ps1" -P2 "PPN-P2-0002"
# ============================================================

[CmdletBinding()]
param(
  [Parameter()][string]$RepoRoot  = "M:\Plantery Pyramid Network",
  [Parameter()][string]$P1        = "PPN-P1-0003",
  [Parameter(Mandatory=$true)][string]$P2,
  [Parameter()][string]$BundleDir
)
# ---- PPN: CANONICAL POINTER WRITE (BEGIN) ----
# If p2AB exists now, write the deterministic pointer file.
if (Get-Variable -Name p2AB -Scope Local -ErrorAction SilentlyContinue) {
  try {
    $ptr = Join-Path $p2AB "AB_inputs_pointer.txt"
    if (-not $script:PPN_POINTER_PAYLOAD) { throw "PPN_POINTER_PAYLOAD missing (unexpected)" }
    [IO.File]::WriteAllText($ptr, $script:PPN_POINTER_PAYLOAD + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
  } catch {
    throw ("Failed writing AB_inputs_pointer.txt: " + $_.Exception.Message)
  }
}
# ---- PPN: CANONICAL POINTER WRITE (END) ----
# ---- PPN: CANONICAL BUNDLE SELECTION + POINTER (BEGIN) ----
# BundleDir is OPTIONAL:
# - If not provided, auto-pick the latest P1 export bundle that CONTAINS best_band.txt.
# - If provided, enforce that it is inside the P1 exports root and contains best_band.txt.
#
# Also writes deterministic AB_inputs_pointer.txt (P1,P2,BundleDir,bestBandPath,git hash).

function Ppn-NormPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  return [IO.Path]::GetFullPath($p).TrimEnd('\','/')
}

function Ppn-GetGitHead([string]$RepoRoot) {
  try {
    $v = (& git -C $RepoRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
  } catch {}
  return "<unknown>"
}

function Ppn-SelectLatestValidBundle([string]$ExportsRoot) {
  if (-not (Test-Path -LiteralPath $ExportsRoot)) {
    throw ("Missing exports root for P1: " + $ExportsRoot)
  }

  $candidates =
    Get-ChildItem -LiteralPath $ExportsRoot -Directory -ErrorAction Stop |
      Where-Object { $_.Name -like "resonance_engine_v1_bundle_*" } |
      ForEach-Object {
        $bb = Join-Path $_.FullName "best_band.txt"
        if (Test-Path -LiteralPath $bb) {
          [PSCustomObject]@{ Dir = $_.FullName; BestBand = $bb; T = $_.LastWriteTimeUtc }
        }
      } |
      Sort-Object T -Descending

  if (-not $candidates -or $candidates.Count -eq 0) {
    throw ("No VALID export bundles found (missing best_band.txt) under: " + $ExportsRoot)
  }

  return $candidates[0]
}

# --- Canonical P1 exports root ---
$exportsRoot = Join-Path $RepoRoot ("05_ANALYSIS\REPORTS\{0}\_EXPORTS" -f $P1)

# --- Resolve BundleDir ---
if (-not $PSBoundParameters.ContainsKey("BundleDir") -or [string]::IsNullOrWhiteSpace($BundleDir)) {
  $pick = Ppn-SelectLatestValidBundle $exportsRoot
  $BundleDir = $pick.Dir
  $bestBandPath = $pick.BestBand
} else {
  if (-not (Test-Path -LiteralPath $BundleDir)) { throw ("Missing BundleDir: " + $BundleDir) }

  # FAIL-FAST: BundleDir must be inside P1 exports root (prevents mixed P1/P2)
  $bdNorm = Ppn-NormPath $BundleDir
  $erNorm = Ppn-NormPath $exportsRoot
  if (-not $bdNorm.StartsWith($erNorm, [StringComparison]::OrdinalIgnoreCase)) {
    throw ("BundleDir is OUTSIDE expected P1 exports root (mixed IDs?). BundleDir=" + $bdNorm + " ; exportsRoot=" + $erNorm)
  }

  $bestBandPath = Join-Path $BundleDir "best_band.txt"
  if (-not (Test-Path -LiteralPath $bestBandPath)) {
    throw ("Missing best_band.txt in provided bundle: " + $bestBandPath)
  }
}

# Extra FAIL-FAST: exports root must exist and contain P1 token in path
if (-not (Test-Path -LiteralPath $exportsRoot)) { throw ("Missing exports root for P1: " + $exportsRoot) }
if ($exportsRoot -notlike ("*" + $P1 + "*")) { throw ("Sanity fail: exportsRoot does not contain P1 token. exportsRoot=" + $exportsRoot) }

Write-Host ("[PPN] BundleDir -> " + $BundleDir) -ForegroundColor DarkCyan
Write-Host ("[PPN] bestBandPath -> " + $bestBandPath) -ForegroundColor DarkCyan

# --- Deterministic pointer artifact (overwrite, canonical) ---
try {
  # p2AB is expected later in the script; but if it already exists here, we can write early.
  # If not, we defer by writing to a temp var and letting the later section use it.
  $script:PPN_POINTER_PAYLOAD = $null

  $gitHead = Ppn-GetGitHead $RepoRoot
  $payload = @(
    "PPN_CANONICAL_POINTER_V1"
    ("timestamp_utc=" + [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"))
    ("git_head=" + $gitHead)
    ("P1=" + $P1)
    ("P2=" + $P2)
    ("exportsRoot=" + (Ppn-NormPath $exportsRoot))
    ("BundleDir=" + (Ppn-NormPath $BundleDir))
    ("bestBandPath=" + (Ppn-NormPath $bestBandPath))
  ) -join "`r`n"

  $script:PPN_POINTER_PAYLOAD = $payload
} catch {
  throw ("Failed to build AB_inputs_pointer payload: " + $_.Exception.Message)
}
# ---- PPN: CANONICAL BUNDLE SELECTION + POINTER (END) ----

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "`n[PPN] A/B packet builder: P1=$P1  P2=$P2" -ForegroundColor Cyan

$ppnPath = Join-Path $RepoRoot "08_AUTOMATION\powershell\ppn.ps1"

# ---- PATHS ----
$p1Proc = Join-Path $RepoRoot ("04_DATA\PROCESSED\{0}\resonance_engine_v1" -f $P1)
$p2Proc = Join-Path $RepoRoot ("04_DATA\PROCESSED\{0}\resonance_engine_v1" -f $P2)
$p2Raw  = Join-Path $RepoRoot ("04_DATA\RAW\{0}" -f $P2)

$seedCfg      = Join-Path $p2Raw "PHASE2_SEED_CONFIG.json"

$p2RptRoot = Join-Path $RepoRoot ("05_ANALYSIS\REPORTS\{0}" -f $P2)
$p2AB      = Join-Path $p2RptRoot "_AB_COMPARE"

$abCsv   = Join-Path $p2AB "AB_compare_P1_vs_P2.csv"
$abBand  = Join-Path $p2AB "AB_in_band_summary.txt"
$abMeta  = Join-Path $p2AB "AB_inputs_pointer.txt"
$readme  = Join-Path $p2AB "README_HANDOFF.md"
$sumFile = Join-Path $p2AB "SHA256SUMS.txt"

# ---- SAFETY CHECKS ----
foreach ($p in @($RepoRoot, $ppnPath, $p1Proc, $p2Raw, $BundleDir, $bestBandPath)) {
  if (-not (Test-Path -LiteralPath $p)) { throw "Missing required path: $p" }
}
# ---- Guard: if P2 RAW missing, stop early (prevents batch poison) ----
if (-not (Test-Path -LiteralPath $p2Raw)) {
  Write-Host "[PPN] SKIP: Missing P2 RAW folder -> $p2Raw" -ForegroundColor Yellow
  return
}

# ---- Ensure P2 outputs exist ----
$csvP2  = Join-Path $p2Proc "resonance_sweep.csv"
$bestP2 = Join-Path $p2Proc "best_band.txt"

if (-not (Test-Path -LiteralPath $csvP2)) {
  Write-Host "[PPN] P2 missing resonance_sweep.csv -> running resonance-summary..." -ForegroundColor Yellow
  & $ppnPath resonance-summary -ExperimentId $P2
}
if (-not (Test-Path -LiteralPath $bestP2)) {
  Write-Host "[PPN] P2 missing best_band.txt -> running resonance-plot..." -ForegroundColor Yellow
  & $ppnPath resonance-plot -ExperimentId $P2
}
if (-not (Test-Path -LiteralPath $csvP2))  { throw "Still missing P2 CSV: $csvP2" }
if (-not (Test-Path -LiteralPath $bestP2)) { throw "Still missing P2 best_band: $bestP2" }

# ---- Create output dir ----
New-Item -ItemType Directory -Force -Path $p2AB | Out-Null

# ---- Write AB pointer/meta ----
@"
P1: $P1
P2: $P2
Phase1 bundle: $BundleDir
P2 seed: $seedCfg
P1 sweep: $(Join-Path $p1Proc "resonance_sweep.csv")
P2 sweep: $(Join-Path $p2Proc "resonance_sweep.csv")
best_band.txt (bundle): $bestBandPath
best_band.txt (p2):     $bestP2
"@ | Set-Content -Encoding UTF8 -LiteralPath $abMeta

# ---- Generate AB CSV + in-band summary ----
$tmpPy = Join-Path $env:TEMP ("ppn_ab_compare_{0}.py" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
@"
import re
import pandas as pd
from pathlib import Path

P1 = r"$P1"
P2 = r"$P2"

p1 = Path(r"$p1Proc") / "resonance_sweep.csv"
p2 = Path(r"$p2Proc") / "resonance_sweep.csv"
best = Path(r"$bestBandPath")

out_csv  = Path(r"$abCsv")
out_band = Path(r"$abBand")

def parse_best_band(path: Path):
    txt = path.read_text(encoding="utf-8", errors="replace").replace("\ufeff","")
    kv = {}
    for line in txt.splitlines():
        m = re.match(r"^\s*([^=]+)\s*=\s*(.+)\s*$", line)
        if m:
            kv[m.group(1).strip()] = float(m.group(2).strip())
    return kv

bb = parse_best_band(best)
band_lo = bb.get("band_lo_hz")
band_hi = bb.get("band_hi_hz")
peak_hz = bb.get("peak_drive_hz")

df1 = pd.read_csv(p1)
df2 = pd.read_csv(p2)

df1.columns = [c.strip().lower() for c in df1.columns]
df2.columns = [c.strip().lower() for c in df2.columns]

key = "drive_hz"
if key not in df1.columns or key not in df2.columns:
    raise SystemExit("Missing drive_hz column in one of the sweeps")

m = df1.merge(df2, on=key, how="outer", suffixes=("_p1","_p2")).sort_values(key)
for metric in ("em_rms","vib_rms","chamber_rms","peak_em_hz"):
    a = f"{metric}_p1"
    b = f"{metric}_p2"
    if a in m.columns and b in m.columns:
        m[f"{metric}_delta"] = m[b] - m[a]

m.to_csv(out_csv, index=False)

band = m[(m[key] >= band_lo) & (m[key] <= band_hi)].copy()
lines = []
lines.append(f"P1={P1}  P2={P2}")
lines.append(f"Band window: {band_lo}-{band_hi} Hz | Peak: {peak_hz} Hz")
lines.append("")
if "em_rms_delta" in band.columns and len(band) > 0:
    lines.append("In-band EM_RMS delta (P2 - P1):")
    lines.append(f"  mean: {band['em_rms_delta'].mean():.6f}")
    lines.append(f"  min : {band['em_rms_delta'].min():.6f}")
    lines.append(f"  max : {band['em_rms_delta'].max():.6f}")
else:
    lines.append("No em_rms_delta column found (check sweep columns).")

out_band.write_text("\\n".join(lines) + "\\n", encoding="utf-8")
print("WROTE", out_csv)
print("WROTE", out_band)
"@ | Set-Content -Encoding UTF8 -LiteralPath $tmpPy

py $tmpPy | Out-Host
if ($LASTEXITCODE -ne 0) { throw "Python compare failed (see error above). Aborting packet build." }

# ---- Generate delta plots ----
$tmpPy2 = Join-Path $env:TEMP ("ppn_ab_plots_{0}.py" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
@"
import pandas as pd
from pathlib import Path
import matplotlib.pyplot as plt
import re

ab_csv = Path(r"$abCsv")
outdir = Path(r"$p2AB")
df = pd.read_csv(ab_csv)
df.columns = [c.strip().lower() for c in df.columns]
x = df["drive_hz"]

def plot_delta(col, fname, title):
    if col not in df.columns:
        print("SKIP missing", col)
        return
    y = df[col]
    plt.figure()
    plt.plot(x, y)
    plt.axhline(0.0)
    plt.title(title)
    plt.xlabel("drive_hz")
    plt.ylabel(col)
    out = outdir / fname
    plt.savefig(out, dpi=160, bbox_inches="tight")
    plt.close()
    print("WROTE", out)

plot_delta("em_rms_delta",      "delta_em_rms_vs_drive_hz.png",      "Delta EM_RMS (P2 - P1) vs drive_hz")
plot_delta("vib_rms_delta",     "delta_vib_rms_vs_drive_hz.png",     "Delta VIB_RMS (P2 - P1) vs drive_hz")
plot_delta("chamber_rms_delta", "delta_chamber_rms_vs_drive_hz.png", "Delta CHAMBER_RMS (P2 - P1) vs drive_hz")

band_txt = outdir / "AB_in_band_summary.txt"
if band_txt.exists():
    txt = band_txt.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"Band window:\s*([0-9.]+)-([0-9.]+)\s*Hz", txt)
    if m:
        lo = float(m.group(1)); hi = float(m.group(2))
        band = df[(df["drive_hz"] >= lo) & (df["drive_hz"] <= hi)].copy()
        if "em_rms_delta" in band.columns and len(band) > 0:
            plt.figure()
            plt.plot(band["drive_hz"], band['em_rms_delta'])
            plt.axhline(0.0)
            plt.title(f"In-band Delta EM_RMS (P2 - P1), {lo}-{hi} Hz")
            plt.xlabel("drive_hz")
            plt.ylabel("em_rms_delta")
            out = outdir / "delta_em_rms_in_band.png"
            plt.savefig(out, dpi=160, bbox_inches="tight")
            plt.close()
            print("WROTE", out)
"@ | Set-Content -Encoding UTF8 -LiteralPath $tmpPy2

py $tmpPy2 | Out-Host

# ---- README + SHA256SUMS ----
$bandTxt = (Get-Content -LiteralPath $abBand -Raw -Encoding UTF8).Trim()
$metaTxt = (Get-Content -LiteralPath $abMeta -Raw -Encoding UTF8).Trim()
@"
# PPN A/B Compare - $P1 vs $P2

This folder is the canonical Phase-1 vs Phase-2 comparison packet.
It is intended to be human-reviewable truth (CSV + plots + pointers + hashes).

## Inputs / Provenance
```
$metaTxt
```

## In-band definition (from Phase-1 best band)
```
$bandTxt
```

## What to open (recommended order)
1) AB_in_band_summary.txt
2) delta_em_rms_in_band.png
3) delta_em_rms_vs_drive_hz.png
4) AB_compare_P1_vs_P2.csv
5) SHA256SUMS.txt

## How to interpret deltas
- All delta plots are P2 - P1.
- Values near 0 across the band mean Phase-2 matches Phase-1 baseline behavior.
- Consistent positive/negative shift in-band implies a systematic change in the band window.
"@ | Set-Content -Encoding UTF8 -LiteralPath $readme

Get-ChildItem -LiteralPath $p2AB -File |
  Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
  Sort-Object Name |
  ForEach-Object {
    $h = Get-FileHash -Algorithm SHA256 $_.FullName
    "{0}  {1}" -f $h.Hash.ToLower(), $_.Name
  } | Set-Content -Encoding ASCII -LiteralPath $sumFile

Push-Location $p2AB
$failed = $false
Get-Content -LiteralPath .\SHA256SUMS.txt | ForEach-Object {
  $hash,$name = $_ -split "\s\s+",2
  $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $name).Hash.ToLower()
  if ($hash -ne $actual) { Write-Host "MISMATCH $name" -ForegroundColor Red; $script:failed = $true }
  else { Write-Host "OK       $name" -ForegroundColor Green }
}
Pop-Location
if ($failed) { throw "Hash verification failed for $P2 packet." }

Write-Host "`n✅ CANONICAL A/B PACKET READY -> $p2AB" -ForegroundColor Green







# ---- BundleDir (operator-grade): auto-pick latest P1 export bundle if not provided ----
$exportsRoot = Join-Path $RepoRoot ("05_ANALYSIS\REPORTS\{0}\_EXPORTS" -f $P1)
if (-not $PSBoundParameters.ContainsKey("BundleDir") -or [string]::IsNullOrWhiteSpace($BundleDir)) {
  if (-not (Test-Path -LiteralPath $exportsRoot)) { throw ("Missing exports root for P1: " + $exportsRoot) }
  $candidate = Get-ChildItem -LiteralPath $exportsRoot -Directory |
    Where-Object { $_.Name -like "resonance_engine_v1_bundle_*" } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if (-not $candidate) { throw ("No export bundles found under: " + $exportsRoot) }
  $BundleDir = $candidate.FullName
}
if (-not (Test-Path -LiteralPath $bestBandPath)) { throw ("Missing best_band.txt in bundle: " + $bestBandPath) }
Write-Host ("[PPN] BundleDir -> " + $BundleDir) -ForegroundColor DarkCyan


