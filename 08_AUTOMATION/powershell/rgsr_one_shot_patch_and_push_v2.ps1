param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [switch]$LinkProject,
  [string]$ProjectRef = "",
  [switch]$ApplyRemote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }

function WriteUtf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir) { EnsureDir $dir }
  [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
  Write-Host ("[OK] WROTE " + $Path) -ForegroundColor DarkGreen
}

function WriteUtf8NoBomIfChanged([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir) { EnsureDir $dir }
  $existing = $null
  if (Test-Path -LiteralPath $Path) { $existing = Get-Content -Raw -LiteralPath $Path -Encoding UTF8 }
  if ($existing -ne $Content) {
    [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
    Write-Host ("[OK] WROTE " + $Path) -ForegroundColor DarkGreen
  } else {
    Write-Host ("[OK] NO-CHANGE " + $Path) -ForegroundColor DarkCyan
  }
}

function Replace-FunctionBlock([string]$SqlText, [string]$QualifiedFnName, [string]$ReplacementBlock) {
  $startPattern = '(?im)^[\t ]*create[\t ]+or[\t ]+replace[\t ]+function[\t ]+' + [Regex]::Escape($QualifiedFnName) + '\b'
  $mStart = [Regex]::Match($SqlText, $startPattern)
  if(-not $mStart.Success){ throw "Function start not found for: $QualifiedFnName" }
  $startIdx = $mStart.Index

  $nextFnPattern = '(?im)^[\t ]*create[\t ]+or[\t ]+replace[\t ]+function\b'
  $tail = $SqlText.Substring($startIdx + 1)
  $mNext = [Regex]::Match($tail, $nextFnPattern)
  $endIdx = $SqlText.Length
  if($mNext.Success){ $endIdx = ($startIdx + 1 + $mNext.Index) }

  $before = $SqlText.Substring(0, $startIdx)
  $after  = $SqlText.Substring($endIdx)

  if(-not $ReplacementBlock.EndsWith("`r`n")) { $ReplacementBlock += "`r`n" }
  return $before + $ReplacementBlock + $after
}

if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "RepoRoot not found: $RepoRoot" }
Set-Location $RepoRoot

$mgDir = Join-Path $RepoRoot "supabase\migrations"
EnsureDir $mgDir

Write-Host ("[INFO] RepoRoot=" + $RepoRoot) -ForegroundColor Gray
Write-Host ("[INFO] mgDir=" + $mgDir) -ForegroundColor Gray

# ==========================================================
# PATCH: latest env_profiles... migration file (in-place)
# ==========================================================
$target = Get-ChildItem -LiteralPath $mgDir -Filter "*_rgsr_env_profiles_geometry_library_and_team_rpc_v1.sql" |
  Sort-Object Name -Descending | Select-Object -First 1
if (-not $target) { throw "Target migration not found: *_rgsr_env_profiles_geometry_library_and_team_rpc_v1.sql" }

$raw = Get-Content -Raw -LiteralPath $target.FullName -Encoding UTF8

# ---- FIX 1: get_lab_team ----
$fixedGetLabTeam = ((@(
"create or replace function rgsr.get_lab_team(p_lab uuid)",
"returns jsonb",
"language sql",
"stable",
"as `$rgsr$",
"  select jsonb_build_object(",
"    'lab_id', p_lab,",
"    'members', coalesce(",
"      (",
"        select jsonb_agg(",
"          jsonb_build_object(",
"            'user_id', up.user_id,",
"            'display_name', up.display_name,",
"            'plan_id', up.plan_id,",
"            'role_id', up.role_id,",
"            'seat_role', lm.seat_role,",
"            'is_owner', (l.owner_id = up.user_id)",
"          )",
"          order by (l.owner_id = up.user_id) desc, lm.created_at asc",
"        )",
"        from rgsr.labs l",
"        join rgsr.lab_members lm on lm.lab_id = l.lab_id",
"        join rgsr.user_profiles up on up.user_id = lm.user_id",
"        where l.lab_id = p_lab",
"          and rgsr.is_lab_member(p_lab)",
"          and rgsr.me_has_lab_capability(p_lab, 'TEAM_ROSTER_VIEW')",
"      ),",
"      '[]'::jsonb",
"    )",
"  );",
"`$rgsr$;"
) -join "`r`n")) + "`r`n"

$raw = Replace-FunctionBlock -SqlText $raw -QualifiedFnName "rgsr.get_lab_team" -ReplacementBlock $fixedGetLabTeam

# ---- FIX 2: get_lab_invites ----
$fixedGetLabInvites = ((@(
"create or replace function rgsr.get_lab_invites(p_lab uuid)",
"returns jsonb",
"language sql",
"stable",
"as `$rgsr$",
"  select jsonb_build_object(",
"    'lab_id', p_lab,",
"    'invites', coalesce(",
"      (",
"        select jsonb_agg(",
"          jsonb_build_object(",
"            'invite_id', li.invite_id,",
"            'email', li.email,",
"            'seat_role', li.seat_role,",
"            'status', li.status,",
"            'created_at', li.created_at,",
"            'expires_at', li.expires_at",
"          )",
"          order by li.created_at desc",
"        )",
"        from rgsr.lab_invites li",
"        where li.lab_id = p_lab",
"          and rgsr.is_lab_member(p_lab)",
"          and rgsr.me_has_lab_capability(p_lab, 'TEAM_INVITES_VIEW')",
"      ),",
"      '[]'::jsonb",
"    )",
"  );",
"`$rgsr$;"
) -join "`r`n")) + "`r`n"

$raw = Replace-FunctionBlock -SqlText $raw -QualifiedFnName "rgsr.get_lab_invites" -ReplacementBlock $fixedGetLabInvites

WriteUtf8NoBomIfChanged $target.FullName $raw
Write-Host ("[OK] PATCHED MIGRATION (team+invites): " + $target.FullName) -ForegroundColor Green

# ==========================================================
# LINK + PUSH
# ==========================================================
if ($LinkProject) {
  if (-not $ProjectRef) { throw "ProjectRef is required for link." }
  & supabase link --project-ref $ProjectRef
  Write-Host "[OK] supabase link complete" -ForegroundColor Green
}

if ($ApplyRemote) {
  cmd /c "echo y| supabase db push"
  Write-Host "[OK] supabase db push complete" -ForegroundColor Green
}

Write-Host "✅ ONE-SHOT PIPELINE COMPLETE (v2)" -ForegroundColor Green