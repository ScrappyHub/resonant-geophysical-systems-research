param(
  [Parameter(Mandatory=True)][string],
  [Parameter(Mandatory=True)][ValidateSet('PHASE1','PHASE2')][string]
)

Stop = 'Stop'
M:\Plantery Pyramid Network = Split-Path -Parent 
 = Split-Path -Parent (Split-Path -Parent M:\Plantery Pyramid Network)

 = Join-Path  "02_EXPERIMENTS\_MULTI_NODE\RUNS"
if (-not (Test-Path )) { New-Item -ItemType Directory -Path  | Out-Null }

 = Join-Path  "02_EXPERIMENTS\TEMPLATES\RUN_SHEET.md"
 = Join-Path  ".md"

if (Test-Path ) { throw "Run sheet already exists: " }

Copy-Item  

# prepend header
 = "# 

(Generated: 2025-12-29 17:14:23)

"
 = Get-Content  -Raw
 +  | Out-File -FilePath  -Encoding utf8

Write-Host "✅ Created run sheet: " -ForegroundColor Green