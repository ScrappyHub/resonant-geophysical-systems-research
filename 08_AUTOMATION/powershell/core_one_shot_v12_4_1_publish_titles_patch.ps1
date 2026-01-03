param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [switch]$LinkProject,
  [string]$ProjectRef = "",
  [switch]$ApplyRemote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function WriteUtf8NoBom([string]$Path, [string]$Content) { [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false))); Write-Host ("[OK] WROTE " + $Path) -ForegroundColor Green }
function Invoke-Supabase([string[]]$SbArgs, [switch]$PipeYes) {
  $argStr = ($SbArgs -join " ")
  if ($PipeYes) { cmd /c ("echo y| supabase " + $argStr) | Out-Host } else { & supabase @SbArgs | Out-Host }
  if ($LASTEXITCODE -ne 0) { throw ("supabase " + $argStr + " failed (exit=" + $LASTEXITCODE + ")") }
}

Set-Location $RepoRoot
$mgDir = Join-Path $RepoRoot "supabase\migrations"
EnsureDir $mgDir
$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_v12_4_1_publish_titles_patch.sql" -f $MigrationId)

$sql = @'
begin;

-- Add missing columns needed by publish submission form.
alter table rgsr.publish_submissions
  add column if not exists title text,
  add column if not exists summary text;

-- Optional: ensure non-empty strings when present (soft checks)
do $do$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='rgsr' and table_name='publish_submissions' and column_name='title'
  ) then
    -- no-op: keep migration lightweight and compatible
    null;
  end if;
end
$do$;

commit;
'@

WriteUtf8NoBom $mgPath ($sql + "`r`n")
Write-Host ("[OK] NEW MIGRATION READY: " + $mgPath) -ForegroundColor Green

if ($LinkProject) {
  if (-not $ProjectRef) { throw "ProjectRef is required for link." }
  Invoke-Supabase -SbArgs @("link","--project-ref",$ProjectRef)
  Write-Host "[OK] supabase link complete" -ForegroundColor Green
}
if ($ApplyRemote) {
  Invoke-Supabase -SbArgs @("db","push") -PipeYes
  Write-Host "[OK] supabase db push complete" -ForegroundColor Green
}

Write-Host "✅ v12.4.1 PATCHED (publish_submissions.title + summary)" -ForegroundColor Green
'@

[IO.File]::WriteAllText($mgPath, $sql, (New-Object Text.UTF8Encoding($false)))
