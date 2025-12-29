param(
  [Parameter(Mandatory=True)][string],
  [Parameter(Mandatory=True)][string]
)

Stop = 'Stop'

M:\Plantery Pyramid Network = Split-Path -Parent 
# Since this script is under 08_AUTOMATION\powershell, root is ...\08_AUTOMATION
# Project root is one level up:
 = Split-Path -Parent M:\Plantery Pyramid Network

 = Join-Path  '04_DATA\RAW' 
 = Join-Path  '04_DATA\METADATA'

 = Join-Path  
if (-not (Test-Path )) { New-Item -ItemType Directory -Path  | Out-Null }

Copy-Item -Path (Join-Path  '*') -Destination  -Recurse -Force

# create metadata stub
 = Join-Path  ".json"
if (-not (Test-Path )) {
   = @{
    experiment_id = 
    ingested_utc = (Get-Date).ToUniversalTime().ToString('o')
    source_dir = 
    raw_dir = 
    notes = ''
  }
   | ConvertTo-Json -Depth 6 | Out-File -FilePath  -Encoding utf8
}

Write-Host "✅ Ingested RAW data to: " -ForegroundColor Green
Write-Host "✅ Metadata: " -ForegroundColor Green