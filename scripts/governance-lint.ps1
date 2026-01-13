param(
  [string]$RepoRoot = (git rev-parse --show-toplevel)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "GOVERNANCE LINT: repo_root=$RepoRoot"

# Required files
$required = @(
  "governance/TRUTH_ADJACENT_BASE_GOVERNANCE.md"
)

$missing = @()
foreach ($f in $required) {
  $p = Join-Path $RepoRoot $f
  if (!(Test-Path $p)) { $missing += $f }
}

if ($missing.Count -gt 0) {
  Write-Error ("Missing required governance files:`n - " + ($missing -join "`n - "))
}

# Basic sanity: ensure base governance is not a stub/redirect
$base = Get-Content (Join-Path $RepoRoot "governance/TRUTH_ADJACENT_BASE_GOVERNANCE.md") -Raw
if ($base -match "intentionally non-authoritative" -or $base -match "NOTICE — GOVERNANCE SOURCE OF TRUTH") {
  Write-Error "TRUTH_ADJACENT_BASE_GOVERNANCE.md appears to be a NOTICE/stub. It must be the binding governance."
}

Write-Host "GOVERNANCE LINT: OK"
