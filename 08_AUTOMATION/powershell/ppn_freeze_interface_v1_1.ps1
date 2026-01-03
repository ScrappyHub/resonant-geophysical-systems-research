param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [string]$EngineVersion = "RGSR_ENGINE_V1_ALPHA",
  [switch]$WriteStarterProfiles,
  [switch]$DoCommit,
  [switch]$DoPush
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

function WriteUtf8NoBomIfChanged([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir) { EnsureDir $dir }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $existing = $null
  if (Test-Path -LiteralPath $Path) { $existing = Get-Content -Raw -LiteralPath $Path -Encoding UTF8 }
  if ($existing -ne $Content) {
    [IO.File]::WriteAllText($Path, $Content, $enc)
    Write-Host ("[OK] WROTE " + $Path) -ForegroundColor DarkGreen
  } else {
    Write-Host ("[OK] NO-CHANGE " + $Path) -ForegroundColor DarkCyan
  }
}

function AppendCanonicalTodo([string]$Path, [string]$Block) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir) { EnsureDir $dir }
  if (-not (Test-Path -LiteralPath $Path)) { [IO.File]::WriteAllText($Path, "# CANONICAL TODO (LOCKED)`r`n`r`n", $enc) }
  $existing = Get-Content -Raw -LiteralPath $Path -Encoding UTF8
  if ($existing -notmatch [regex]::Escape($Block.Trim())) {
    [IO.File]::WriteAllText($Path, ($existing.TrimEnd() + "`r`n`r`n" + $Block.TrimEnd() + "`r`n"), $enc)
    Write-Host ("[OK] TODO APPENDED " + $Path) -ForegroundColor DarkGreen
  } else {
    Write-Host ("[OK] TODO EXISTS " + $Path) -ForegroundColor DarkCyan
  }
}

# ----------------------------
# 1) Engine version (Layer 1 contract)
# ----------------------------
$verPath = Join-Path $RepoRoot "RGSR_ENGINE_VERSION.txt"
WriteUtf8NoBomIfChanged $verPath ($EngineVersion + "`r`n")

# ----------------------------
# 2) Canonical output contract doc
# ----------------------------
$docDir = Join-Path $RepoRoot "09_DOCS\CANONICAL"
EnsureDir $docDir
$outContractPath = Join-Path $docDir "ENGINE_OUTPUT_CONTRACT.md"
$out = @()
$out += "# RGSR / PPN Engine Output Contract (V1)"
$out += ""
$out += "**Status:** LOCKED"
$out += "**Scope:** Layer 1 (Core Engine) output naming + presence expectations."
$out += ""
$out += "## Required Run Artifacts (minimum set)"
$out += "Produced under:"
$out += '`05_ANALYSIS/REPORTS/<P2>/_AB_COMPARE/`'
$out += ""
$out += "### Must Exist"
$out += "- RUN_CONDITIONS.json"
$out += "- SHA256SUMS.txt"
$out += "- AB_inputs_pointer.txt"
$out += ""
$out += "### Expected (when AB compare artifacts exist)"
$out += "- AB_compare_P1_vs_P2.csv"
$out += "- AB_in_band_summary.txt"
$out += ""
$out += "### Optional (if produced by analyzers)"
$out += "- delta_em_rms_in_band.png"
$out += "- delta_em_rms_vs_drive_hz.png"
$out += "- delta_vib_rms_vs_drive_hz.png"
$out += "- delta_chamber_rms_vs_drive_hz.png"
$out += ""
$out += "## Invariants"
$out += '- Layer 1 produces **no identity** and performs **no network calls**.'
$out += '- Any "publication" or "lane promotion" is Layer 2/3 only.'
$out += "- Outputs are append-only."
$out += ""
$out += "## Schema IDs (stable strings)"
$out += '- RUN_CONDITIONS schema: `PPN_RUN_CONDITIONS_V1`'
$out += '- Pointer footer marker: `PPN_REPRODUCIBILITY_V1`'
$outText = ($out -join "`r`n") + "`r`n"
WriteUtf8NoBomIfChanged $outContractPath $outText

# ----------------------------
# 3) Condition Profile JSON Schema (V1.1)
# ----------------------------
$condDir = Join-Path $RepoRoot "conditions"
$profilesDir = Join-Path $condDir "profiles"
$schemaDir = Join-Path $condDir "schema"
EnsureDir $profilesDir
EnsureDir $schemaDir
$schemaPath = Join-Path $schemaDir "condition_profile.schema.json"
$schemaJson = @'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "RGSR_CONDITION_PROFILE_V1_1",
  "title": "RGSR Condition Profile V1.1",
  "type": "object",
  "additionalProperties": true,
  "required": ["profile", "environment", "mounting", "drive_profile", "sensor_pack", "sample_id"],
  "properties": {
    "profile": { "type": "string", "minLength": 1 },
    "environment": { "type": "string" },
    "temp_c": { "type": "number" },
    "humidity_rh": { "type": "number" },
    "pressure_kpa": { "type": "number" },
    "season": { "type": "string", "enum": ["spring","summer","autumn","winter"] },
    "weather": { "type": "string", "enum": ["dry","rain","snow","fog","windy","storm"] },
    "mounting": { "type": "string", "minLength": 1 },
    "drive_profile": { "type": "string", "minLength": 1 },
    "sensor_pack": { "type": "string", "minLength": 1 },
    "sample_id": { "type": "string", "minLength": 1 },
    "thermal": {
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "ambient_temp_c": { "type": "number" },
        "internal_air_temp_c": { "type": "number" },
        "water_temp_c": { "type": "number" },
        "inlet_water_temp_c": { "type": "number" },
        "surface_temp_c": { "type": "number" },
        "notes": { "type": "string" }
      }
    },
    "water": {
      "type": "object",
      "additionalProperties": true,
      "properties": {
        "enabled": { "type": "boolean" },
        "level_mm": { "type": "number" },
        "water_temp_c": { "type": "number" },
        "inlet_water_temp_c": { "type": "number" },
        "conductivity_us_cm": { "type": "number" },
        "salinity_ppt": { "type": "number" },
        "flow": { "type": "string" }
      }
    },
    "geometry": { "type": "object", "additionalProperties": true },
    "materials": { "type": "object", "additionalProperties": true }
  }
}
'@
$schemaText = $schemaJson.TrimEnd() + "`r`n"
WriteUtf8NoBomIfChanged $schemaPath $schemaText

# ----------------------------
# 4) Canonical doc: Condition Profiles (V1.1)
# ----------------------------
$condDocPath = Join-Path $docDir "CONDITION_PROFILES.md"
$d = @()
$d += "# RGSR Condition Profiles (V1.1)"
$d += ""
$d += "**Status:** LOCKED"
$d += 'Profiles live in: `conditions/profiles/*.json`'
$d += 'Schema: `conditions/schema/condition_profile.schema.json` (ID: RGSR_CONDITION_PROFILE_V1_1)'
$d += ""
$d += "## Rules"
$d += "- Profiles are immutable templates. If conditions change, create a new profile."
$d += "- Runs reference a profile by name (ConditionProfile) or by explicit file path (ConditionsPath)."
$d += "- If `-RequireConditions` is used, the required fields must exist."
$d += ""
$d += "## Environmental fields"
$d += "- temp_c, humidity_rh, pressure_kpa"
$d += "- season (spring|summer|autumn|winter)"
$d += "- weather (dry|rain|snow|fog|windy|storm)"
$d += ""
$d += "## Thermal sub-domain (recommended)"
$d += "- thermal.ambient_temp_c"
$d += "- thermal.internal_air_temp_c"
$d += "- thermal.water_temp_c"
$d += "- thermal.inlet_water_temp_c"
$d += "- thermal.surface_temp_c"
$d += ""
$d += "These fields are provenance-only. They do not assert physics effects; they enable reproducible comparison."
$docText = ($d -join "`r`n") + "`r`n"
WriteUtf8NoBomIfChanged $condDocPath $docText

# ----------------------------
# 5) Optional: starter profiles
# ----------------------------
if ($WriteStarterProfiles) {
  $p1 = @'
{
  "profile": "DRY_BASELINE_V1_1",
  "environment": "lab",
  "temp_c": 22,
  "humidity_rh": 45,
  "pressure_kpa": 101.3,
  "season": "winter",
  "weather": "dry",
  "mounting": "MOUNT_V1",
  "drive_profile": "DRIVE_SWEEP_0_150HZ_V1",
  "sensor_pack": "SENS_V1",
  "sample_id": "SAMPLE_V1",
  "thermal": { "ambient_temp_c": 22, "internal_air_temp_c": 22 },
  "water": { "enabled": false, "level_mm": 0 }
}
'@
  $p2 = @'
{
  "profile": "COLD_BASELINE_V1_1",
  "environment": "lab",
  "temp_c": 8,
  "humidity_rh": 45,
  "pressure_kpa": 101.3,
  "season": "winter",
  "weather": "dry",
  "mounting": "MOUNT_V1",
  "drive_profile": "DRIVE_SWEEP_0_150HZ_V1",
  "sensor_pack": "SENS_V1",
  "sample_id": "SAMPLE_V1",
  "thermal": { "ambient_temp_c": 8, "internal_air_temp_c": 8 },
  "water": { "enabled": false, "level_mm": 0 }
}
'@
  $p3 = @'
{
  "profile": "HOT_BASELINE_V1_1",
  "environment": "lab",
  "temp_c": 38,
  "humidity_rh": 45,
  "pressure_kpa": 101.3,
  "season": "summer",
  "weather": "dry",
  "mounting": "MOUNT_V1",
  "drive_profile": "DRIVE_SWEEP_0_150HZ_V1",
  "sensor_pack": "SENS_V1",
  "sample_id": "SAMPLE_V1",
  "thermal": { "ambient_temp_c": 38, "internal_air_temp_c": 38 },
  "water": { "enabled": false, "level_mm": 0 }
}
'@
  WriteUtf8NoBomIfChanged (Join-Path $profilesDir "DRY_BASELINE_V1_1.json")  ($p1.TrimEnd() + "`r`n")
  WriteUtf8NoBomIfChanged (Join-Path $profilesDir "COLD_BASELINE_V1_1.json") ($p2.TrimEnd() + "`r`n")
  WriteUtf8NoBomIfChanged (Join-Path $profilesDir "HOT_BASELINE_V1_1.json")  ($p3.TrimEnd() + "`r`n")
}

# ----------------------------
# 6) Cleanup: remove accidental doc if it exists
# ----------------------------
$badDoc = Join-Path $RepoRoot "01_DOCS\MODEL\CONDITION_PROFILES.md"
if (Test-Path -LiteralPath $badDoc) {
  Remove-Item -LiteralPath $badDoc -Force
  Write-Host ("[OK] REMOVED accidental file: " + $badDoc) -ForegroundColor DarkYellow
}

# ----------------------------
# 7) Canonical TODO append (locked)
# ----------------------------
$todoPath = Join-Path $docDir "CANONICAL_TODO.md"
$todoBlock = @()
$todoBlock += "## RGSR CORE INTERFACE FREEZE V1.1"
$todoBlock += ""
$todoBlock += "- [ ] Confirm `CONDITION_PROFILES.md` is present under `09_DOCS/CANONICAL`."
$todoBlock += "- [ ] (Optional) Seed starter profiles (DRY/COLD/HOT) and commit."
$todoBlock += "- [ ] Confirm accidental `01_DOCS/MODEL/CONDITION_PROFILES.md` is absent (repo hygiene)."
$todoBlock += "- [ ] Lock execution path: use `08_AUTOMATION/powershell/ppn_freeze_interface_v1_1.ps1` only."
$todoBlock += ""
$todoText = ($todoBlock -join "`r`n") + "`r`n"
AppendCanonicalTodo $todoPath $todoText

# ----------------------------
# 8) Git (optional)
# ----------------------------
if ($DoCommit) {
  git add -- "RGSR_ENGINE_VERSION.txt" "09_DOCS\CANONICAL\ENGINE_OUTPUT_CONTRACT.md" "09_DOCS\CANONICAL\CONDITION_PROFILES.md" "09_DOCS\CANONICAL\CANONICAL_TODO.md" "conditions\schema\condition_profile.schema.json"
  if ($WriteStarterProfiles) {
    git add -- "conditions\profiles\DRY_BASELINE_V1_1.json" "conditions\profiles\COLD_BASELINE_V1_1.json" "conditions\profiles\HOT_BASELINE_V1_1.json"
  }
  $staged = git diff --cached --name-only
  if (-not $staged) {
    Write-Host "[OK] Nothing staged; no commit needed." -ForegroundColor DarkCyan
  } else {
    git commit -m "rgsr: freeze interface v1.1 (env fields + condition profiles schema/docs + output contract + todo)"
    Write-Host "[OK] COMMITTED" -ForegroundColor Green
    if ($DoPush) { git push; Write-Host "[OK] PUSHED" -ForegroundColor Green }
  }
} else {
  Write-Host "[NOTE] DoCommit not set; no git actions performed." -ForegroundColor Yellow
}

Write-Host "✅ RGSR CORE INTERFACE FREEZE V1.1 COMPLETE" -ForegroundColor Green
