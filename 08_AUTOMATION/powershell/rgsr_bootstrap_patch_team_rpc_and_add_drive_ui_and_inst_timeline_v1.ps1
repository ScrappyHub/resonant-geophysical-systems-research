param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [string]$MigrationId = "",
  [switch]$LinkProject,
  [string]$ProjectRef = "",
  [switch]$ApplyRemote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
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

if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "RepoRoot not found: $RepoRoot" }
Set-Location $RepoRoot

$mgDir = Join-Path $RepoRoot "supabase\migrations"
EnsureDir $mgDir

if (-not $MigrationId) { $MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss") }
$mgPath = Join-Path $mgDir ("{0}_rgsr_drive_profiles_ui_and_institution_timeline_v1.sql" -f $MigrationId)

# ------------------------------------------------------------
# 1) PATCH: Fix failing get_lab_team() in the older pending migration
# ------------------------------------------------------------
$target = Get-ChildItem -LiteralPath $mgDir -Filter "*_rgsr_env_profiles_geometry_library_and_team_rpc_v1.sql" | Select-Object -First 1
if (-not $target) { throw "Target migration not found: *_rgsr_env_profiles_geometry_library_and_team_rpc_v1.sql" }
$raw = Get-Content -Raw -LiteralPath $target.FullName -Encoding UTF8

# Replace the entire get_lab_team(...) function block with a corrected version
$pattern = "(?is)create\s+or\s+replace\s+function\s+rgsr\.get_lab_team\s*\(\s*p_lab\s+uuid\s*\)\s*returns\s+jsonb\s*language\s+sql\s+stable\s+as\s+\$\$.*?\$\$;"

$replacement = @(
"create or replace function rgsr.get_lab_team(p_lab uuid)"
"returns jsonb"
"language sql stable as $$"
"$$;"" ) -join \"`r`n\"

$patched = [System.Text.RegularExpressions.Regex]::Replace($raw, $pattern, $replacement)
if ($patched -eq $raw) { throw "Patch did not apply (pattern not found). Migration unchanged: $($target.FullName)" }
WriteUtf8NoBomIfChanged $target.FullName $patched
Write-Host ("[OK] PATCHED MIGRATION: " + $target.FullName) -ForegroundColor Green

# ------------------------------------------------------------
# 2) NEW MIGRATION: Drive Profiles UI RPC + Institution Application Event Log
# ------------------------------------------------------------
$sqlLines = New-Object System.Collections.Generic.List[string]

$sqlLines.Add('-- ============================================================')
$sqlLines.Add('-- RGSR: Drive Profiles UI RPC (computed C/F) + Institution App Timeline (audit trail)')
$sqlLines.Add('-- ============================================================')
$sqlLines.Add('')
$sqlLines.Add('begin;')
$sqlLines.Add('')
$sqlLines.Add('-- ------------------------------------------------------------')
$sqlLines.Add('-- 0) Temp conversion helpers (canonical, pure SQL)')
$sqlLines.Add('-- ------------------------------------------------------------')
$sqlLines.Add('create or replace function rgsr.c_to_f(p_c numeric) returns numeric language sql immutable as $$')
$sqlLines.Add('  select (p_c * 9.0/5.0) + 32.0;')
$sqlLines.Add('$$;')
$sqlLines.Add('')
$sqlLines.Add('create or replace function rgsr.f_to_c(p_f numeric) returns numeric language sql immutable as $$')
$sqlLines.Add('  select (p_f - 32.0) * 5.0/9.0;')
$sqlLines.Add('$$;')
$sqlLines.Add('')
$sqlLines.Add('-- ------------------------------------------------------------')
$sqlLines.Add('-- 1) Drive Profiles UI RPC: returns computed drive_json using user temp_unit')
$sqlLines.Add('--    Rules:')
$sqlLines.Add('--      - Always returns temp_unit so clients can render labels confidently')
$sqlLines.Add('--      - If user prefers F, converts known temperature paths when present')
$sqlLines.Add('--      - If paths absent, returns unchanged drive_json (still deterministic)')
$sqlLines.Add('-- ------------------------------------------------------------')
$sqlLines.Add('create or replace function rgsr._apply_temp_unit_to_drive_json(p_drive jsonb, p_unit text)')
$sqlLines.Add('returns jsonb')
$sqlLines.Add('language plpgsql')
$sqlLines.Add('stable as $$')
$sqlLines.Add('declare')
$sqlLines.Add('  outj jsonb := p_drive;')
$sqlLines.Add('  v numeric;')
$sqlLines.Add('begin')
$sqlLines.Add('  if p_drive is null then')
$sqlLines.Add('    return null;')
$sqlLines.Add('  end if;')
$sqlLines.Add('')
$sqlLines.Add('  -- Units annotation (non-destructive)')
$sqlLines.Add('  if jsonb_typeof(outj->''units'') = ''object'' then')
$sqlLines.Add('    outj := jsonb_set(outj, ''{units,temp}'', to_jsonb(p_unit), true);')
$sqlLines.Add('  else')
$sqlLines.Add('    outj := jsonb_set(outj, ''{units}'', jsonb_build_object(''temp'', p_unit), true);')
$sqlLines.Add('  end if;')
$sqlLines.Add('')
$sqlLines.Add('  if p_unit <> ''F'' then')
$sqlLines.Add('    return outj;')
$sqlLines.Add('  end if;')
$sqlLines.Add('')
$sqlLines.Add('  -- Known optional paths (future-proof):')
$sqlLines.Add('  -- drive_json.external_conditions.ambient_temp_c')
$sqlLines.Add('  if (outj #>> ''{external_conditions,ambient_temp_c}'') is not null then')
$sqlLines.Add('    v := (outj #>> ''{external_conditions,ambient_temp_c}'')::numeric;')
$sqlLines.Add('    outj := jsonb_set(outj, ''{external_conditions,ambient_temp_f}'', to_jsonb(rgsr.c_to_f(v)), true);')
$sqlLines.Add('  end if;')
$sqlLines.Add('  -- drive_json.internal_chamber.chamber_temp_c')
$sqlLines.Add('  if (outj #>> ''{internal_chamber,chamber_temp_c}'') is not null then')
$sqlLines.Add('    v := (outj #>> ''{internal_chamber,chamber_temp_c}'')::numeric;')
$sqlLines.Add('    outj := jsonb_set(outj, ''{internal_chamber,chamber_temp_f}'', to_jsonb(rgsr.c_to_f(v)), true);')
$sqlLines.Add('  end if;')
$sqlLines.Add('  -- drive_json.water_domain.water_temp_c')
$sqlLines.Add('  if (outj #>> ''{water_domain,water_temp_c}'') is not null then')
$sqlLines.Add('    v := (outj #>> ''{water_domain,water_temp_c}'')::numeric;')
$sqlLines.Add('    outj := jsonb_set(outj, ''{water_domain,water_temp_f}'', to_jsonb(rgsr.c_to_f(v)), true);')
$sqlLines.Add('  end if;')
$sqlLines.Add('')
$sqlLines.Add('  return outj;')
$sqlLines.Add('end;')
$sqlLines.Add('$$;')
$sqlLines.Add('')
$sqlLines.Add('create or replace function rgsr.get_drive_profiles_ui(p_lab uuid default null)')
$sqlLines.Add('returns jsonb')
$sqlLines.Add('language sql')
$sqlLines.Add('stable as $$')
$sqlLines.Add('  with pref as (')
$sqlLines.Add('    select coalesce((select p.temp_unit::text from rgsr.user_preferences p where p.user_id = auth.uid()), ''C'') as unit')
$sqlLines.Add('  ), profiles as (')
$sqlLines.Add('    select')
$sqlLines.Add('      dp.drive_profile_id, dp.name, dp.description, dp.lane::text as lane, dp.is_template,')
$sqlLines.Add('      dp.engine_code, dp.owner_id, dp.lab_id, dp.created_at, dp.updated_at,')
$sqlLines.Add('      dp.drive_json as drive_json_raw,')
$sqlLines.Add('      rgsr._apply_temp_unit_to_drive_json(dp.drive_json, (select unit from pref)) as drive_json_computed')
$sqlLines.Add('    from rgsr.drive_profiles dp')
$sqlLines.Add('    where rgsr.can_read_drive_profile(dp.lane, dp.owner_id, dp.lab_id)')
$sqlLines.Add('      and (p_lab is null or dp.lab_id = p_lab or dp.lab_id is null)')
$sqlLines.Add('  )')
$sqlLines.Add('  select jsonb_build_object(')
$sqlLines.Add('    ''temp_unit'', (select unit from pref),')
$sqlLines.Add('    ''profiles'', coalesce((')
$sqlLines.Add('      select jsonb_agg(jsonb_build_object(')
$sqlLines.Add('        ''drive_profile_id'', p.drive_profile_id,')
$sqlLines.Add('        ''name'', p.name,')
$sqlLines.Add('        ''description'', p.description,')
$sqlLines.Add('        ''lane'', p.lane,')
$sqlLines.Add('        ''is_template'', p.is_template,')
$sqlLines.Add('        ''engine_code'', p.engine_code,')
$sqlLines.Add('        ''owner_id'', p.owner_id,')
$sqlLines.Add('        ''lab_id'', p.lab_id,')
$sqlLines.Add('        ''created_at'', p.created_at,')
$sqlLines.Add('        ''updated_at'', p.updated_at,')
$sqlLines.Add('        ''drive_json_raw'', p.drive_json_raw,')
$sqlLines.Add('        ''drive_json_computed'', p.drive_json_computed')
$sqlLines.Add('      ) order by (p.is_template) desc, p.updated_at desc)')
$sqlLines.Add('      from profiles p')
$sqlLines.Add('    ), ''[]''::jsonb)')
$sqlLines.Add('  );')
$sqlLines.Add('$$;')
$sqlLines.Add('')
$sqlLines.Add('grant execute on function rgsr.get_drive_profiles_ui(uuid) to authenticated;')
$sqlLines.Add('')
$sqlLines.Add('-- ------------------------------------------------------------')
$sqlLines.Add('-- 2) Institution Application Event Log (canonical timeline)')
$sqlLines.Add('-- ------------------------------------------------------------')
$sqlLines.Add('create table if not exists rgsr.institution_application_events (')
$sqlLines.Add('  event_id uuid primary key default gen_random_uuid(),')
$sqlLines.Add('  application_id uuid not null references rgsr.institution_access_applications(application_id) on delete cascade,')
$sqlLines.Add('  actor_user_id uuid references auth.users(id) on delete set null,')
$sqlLines.Add('  event_type text not null,')
$sqlLines.Add('  from_status text,')
$sqlLines.Add('  to_status text,')
$sqlLines.Add('  note text,')
$sqlLines.Add('  metadata jsonb not null default ''{}''::jsonb,')
$sqlLines.Add('  created_at timestamptz not null default now()')
$sqlLines.Add(');')
$sqlLines.Add('')
$sqlLines.Add('create index if not exists ix_inst_app_events_app_time')
$sqlLines.Add('  on rgsr.institution_application_events(application_id, created_at asc);')
$sqlLines.Add('')
$sqlLines.Add('alter table rgsr.institution_application_events enable row level security;')
$sqlLines.Add('')
$sqlLines.Add('-- Applicant can read their own app events; admin can read all')
$sqlLines.Add('drop policy if exists inst_ev_select on rgsr.institution_application_events;')
$sqlLines.Add('create policy inst_ev_select on rgsr.institution_application_events for select to authenticated')
$sqlLines.Add('using (')
$sqlLines.Add('  rgsr.is_sys_admin()')
$sqlLines.Add('  or exists (')
$sqlLines.Add('    select 1 from rgsr.institution_access_applications a')
$sqlLines.Add('    where a.application_id = institution_application_events.application_id')
$sqlLines.Add('      and a.applicant_user_id = auth.uid()')
$sqlLines.Add('  )')
$sqlLines.Add(');')
$sqlLines.Add('')
$sqlLines.Add('-- Only sys_admin/service_role may insert events directly (normally via triggers / admin RPC)')
$sqlLines.Add('drop policy if exists inst_ev_insert on rgsr.institution_application_events;')
$sqlLines.Add('create policy inst_ev_insert on rgsr.institution_application_events for insert to authenticated')
$sqlLines.Add('with check (rgsr.is_sys_admin() or rgsr.is_service_role());')
$sqlLines.Add('')
$sqlLines.Add('-- No updates/deletes (immutable audit trail)')
$sqlLines.Add('drop policy if exists inst_ev_update on rgsr.institution_application_events;')
$sqlLines.Add('create policy inst_ev_update on rgsr.institution_application_events for update to authenticated')
$sqlLines.Add('using (false) with check (false);')
$sqlLines.Add('')
$sqlLines.Add('drop policy if exists inst_ev_delete on rgsr.institution_application_events;')
$sqlLines.Add('create policy inst_ev_delete on rgsr.institution_application_events for delete to authenticated')
$sqlLines.Add('using (false);')
$sqlLines.Add('')
$sqlLines.Add('create or replace function rgsr._log_institution_app_event(')
$sqlLines.Add('  p_app uuid,')
$sqlLines.Add('  p_type text,')
$sqlLines.Add('  p_from text,')
$sqlLines.Add('  p_to text,')
$sqlLines.Add('  p_note text default null,')
$sqlLines.Add('  p_meta jsonb default ''{}''::jsonb')
$sqlLines.Add(') returns void')
$sqlLines.Add('language plpgsql')
$sqlLines.Add('security definer')
$sqlLines.Add('set search_path = rgsr, public, auth as $$')
$sqlLines.Add('begin')
$sqlLines.Add('  insert into rgsr.institution_application_events(application_id, actor_user_id, event_type, from_status, to_status, note, metadata)')
$sqlLines.Add('  values (p_app, auth.uid(), p_type, p_from, p_to, p_note, coalesce(p_meta, ''{}''::jsonb));')
$sqlLines.Add('end;')
$sqlLines.Add('$$;')
$sqlLines.Add('')
$sqlLines.Add('revoke all on function rgsr._log_institution_app_event(uuid, text, text, text, text, jsonb) from public;')
$sqlLines.Add('grant execute on function rgsr._log_institution_app_event(uuid, text, text, text, text, jsonb) to authenticated;')
$sqlLines.Add('')
$sqlLines.Add('create or replace function rgsr.tg_institution_app_timeline()')
$sqlLines.Add('returns trigger')
$sqlLines.Add('language plpgsql as $$')
$sqlLines.Add('begin')
$sqlLines.Add('  if (tg_op = ''INSERT'') then')
$sqlLines.Add('    perform rgsr._log_institution_app_event(new.application_id, ''CREATED'', null, new.status::text, null, jsonb_build_object(''org_name'', new.org_name));')
$sqlLines.Add('    if new.status::text = ''SUBMITTED'' then')
$sqlLines.Add('      perform rgsr._log_institution_app_event(new.application_id, ''SUBMITTED'', ''DRAFT'', ''SUBMITTED'', null, ''{}''::jsonb);')
$sqlLines.Add('    end if;')
$sqlLines.Add('    return new;')
$sqlLines.Add('  end if;')
$sqlLines.Add('')
$sqlLines.Add('  if (tg_op = ''UPDATE'') then')
$sqlLines.Add('    if new.status is distinct from old.status then')
$sqlLines.Add('      perform rgsr._log_institution_app_event(new.application_id, ''STATUS_CHANGED'', old.status::text, new.status::text, new.decision_reason, ''{}''::jsonb);')
$sqlLines.Add('    end if;')
$sqlLines.Add('    if new.billing_verified_at is distinct from old.billing_verified_at and new.billing_verified_at is not null then')
$sqlLines.Add('      perform rgsr._log_institution_app_event(new.application_id, ''BILLING_VERIFIED'', coalesce(old.status::text, null), coalesce(new.status::text, null), null,')
$sqlLines.Add('        jsonb_build_object(''provider'', new.billing_provider, ''customer_id'', new.billing_customer_id, ''subscription_id'', new.billing_subscription_id));')
$sqlLines.Add('    end if;')
$sqlLines.Add('    if new.activated_at is distinct from old.activated_at and new.activated_at is not null then')
$sqlLines.Add('      perform rgsr._log_institution_app_event(new.application_id, ''ACTIVATED'', coalesce(old.status::text, null), coalesce(new.status::text, null), null, ''{}''::jsonb);')
$sqlLines.Add('    end if;')
$sqlLines.Add('    return new;')
$sqlLines.Add('  end if;')
$sqlLines.Add('')
$sqlLines.Add('  return new;')
$sqlLines.Add('end;')
$sqlLines.Add('$$;')
$sqlLines.Add('')
$sqlLines.Add('do $$')
$sqlLines.Add('begin')
$sqlLines.Add('  if not exists (select 1 from pg_trigger where tgname = ''tr_inst_apps_timeline'') then')
$sqlLines.Add('    create trigger tr_inst_apps_timeline')
$sqlLines.Add('    after insert or update on rgsr.institution_access_applications')
$sqlLines.Add('    for each row execute function rgsr.tg_institution_app_timeline();')
$sqlLines.Add('  end if;')
$sqlLines.Add('end$$;')
$sqlLines.Add('')
$sqlLines.Add('create or replace function rgsr.get_my_institution_application_timeline(p_application_id uuid)')
$sqlLines.Add('returns jsonb')
$sqlLines.Add('language sql')
$sqlLines.Add('stable as $$')
$sqlLines.Add('  select jsonb_build_object(')
$sqlLines.Add('    ''application_id'', p_application_id,')
$sqlLines.Add('    ''events'', coalesce((')
$sqlLines.Add('      select jsonb_agg(jsonb_build_object(')
$sqlLines.Add('        ''event_id'', e.event_id,')
$sqlLines.Add('        ''event_type'', e.event_type,')
$sqlLines.Add('        ''from_status'', e.from_status,')
$sqlLines.Add('        ''to_status'', e.to_status,')
$sqlLines.Add('        ''note'', e.note,')
$sqlLines.Add('        ''metadata'', e.metadata,')
$sqlLines.Add('        ''actor_user_id'', e.actor_user_id,')
$sqlLines.Add('        ''created_at'', e.created_at')
$sqlLines.Add('      ) order by e.created_at asc)')
$sqlLines.Add('      from rgsr.institution_application_events e')
$sqlLines.Add('      where e.application_id = p_application_id')
$sqlLines.Add('    ), ''[]''::jsonb)')
$sqlLines.Add('  );')
$sqlLines.Add('$$;')
$sqlLines.Add('')
$sqlLines.Add('grant execute on function rgsr.get_my_institution_application_timeline(uuid) to authenticated;')
$sqlLines.Add('')
$sqlLines.Add('commit;')
$sqlLines.Add('')
$sqlLines.Add('-- ============================================================')
$sqlLines.Add('-- End migration')
$sqlLines.Add('-- ============================================================')

$sql = ($sqlLines -join "`r`n") + "`r`n"
WriteUtf8NoBomIfChanged $mgPath $sql
Write-Host ("[OK] MIGRATION READY: " + $mgPath) -ForegroundColor Green

if ($LinkProject) {
  if (-not $ProjectRef) { throw "ProjectRef is required for link." }
  supabase link --project-ref $ProjectRef
}

if ($ApplyRemote) {
  supabase db push
}

Write-Host "✅ PATCH + DRIVE UI + INSTITUTION TIMELINE PIPELINE COMPLETE" -ForegroundColor Green
