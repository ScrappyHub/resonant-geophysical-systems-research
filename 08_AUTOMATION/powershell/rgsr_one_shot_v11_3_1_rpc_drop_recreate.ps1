param(
  [Parameter(Mandatory)][string]$RepoRoot,
  [switch]$LinkProject,
  [string]$ProjectRef = "",
  [switch]$ApplyRemote
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

function WriteUtf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir) { EnsureDir $dir }
  [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
  Write-Host ("[OK] WROTE " + $Path) -ForegroundColor DarkGreen
}

function Invoke-Supabase([string[]]$SbArgs, [switch]$PipeYes) {
  if (-not $SbArgs -or $SbArgs.Count -eq 0) { throw "Invoke-Supabase called with empty args" }
  $argStr = ($SbArgs -join " ")
  if ($PipeYes) {
    cmd /c ("echo y| supabase " + $argStr) | Out-Host
    $code = $LASTEXITCODE
  } else {
    & supabase @SbArgs
    $code = $LASTEXITCODE
  }
  if ($code -ne 0) { throw ("supabase " + $argStr + " failed (exit=" + $code + ")") }
}

if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "RepoRoot not found: $RepoRoot" }
Set-Location $RepoRoot

$mgDir = Join-Path $RepoRoot "supabase\migrations"
EnsureDir $mgDir

Write-Host ("[INFO] RepoRoot=" + $RepoRoot) -ForegroundColor Gray
Write-Host ("[INFO] mgDir=" + $mgDir) -ForegroundColor Gray

$sb = (Get-Command supabase -ErrorAction SilentlyContinue)
if (-not $sb) { throw "supabase CLI not found in PATH." }

$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_v11_3_1_rpc_drop_recreate.sql" -f $MigrationId)

$sql = @'
-- ============================================================
-- RGSR v11.3.1 — DROP+RECREATE RPCs (FIX RETURN TYPE CONFLICTS)
-- - Drops existing submit_* RPCs (any signature) then recreates
-- - actor_uid() from JWT sub claim
-- - submit_* are SECURITY INVOKER + AUTH_REQUIRED
-- - list_* RPCs for UI (no guessing)
-- - Does NOT touch auth schema / MFA
-- ============================================================

begin;

-- Guard
do $do$
begin
  if to_regnamespace('rgsr') is null then
    raise exception 'rgsr schema missing';
  end if;
end
$do$;

-- ------------------------------------------------------------
-- 0) Drop conflicting functions by name (all overloads)
-- ------------------------------------------------------------
do $do$
declare r record;
begin
  -- drop submit_forum_post overloads
  for r in
    select p.oid, n.nspname as schema_name, p.proname as fn_name,
           pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname='rgsr' and p.proname in (
      'submit_forum_post',
      'submit_research_upload',
      'list_forum_posts',
      'list_research_uploads',
      'actor_uid'
    )
  loop
    execute format('drop function if exists %I.%I(%s) cascade', r.schema_name, r.fn_name, r.args);
  end loop;
end
$do$;

-- ------------------------------------------------------------
-- 1) Canonical actor uid resolver (Supabase claim compatible)
-- ------------------------------------------------------------
create function rgsr.actor_uid()
returns uuid
language sql
stable
as $fn$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$fn$;

alter function rgsr.actor_uid() set search_path = rgsr, public;

-- ------------------------------------------------------------
-- 2) submit_forum_post (SECURITY INVOKER; created_by always actor uid)
-- ------------------------------------------------------------
create function rgsr.submit_forum_post(
  p_topic_slug text,
  p_title text,
  p_body text,
  p_tags text[] default '{}'::text[]
) returns uuid
language plpgsql
security invoker
as $fn$
declare
  v_uid uuid;
  v_topic_id uuid;
  v_ok boolean;
  v_reason text;
  v_title text;
  v_body text;
  v_post_id uuid;
begin
  v_uid := rgsr.actor_uid();
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode='28000';
  end if;

  select topic_id into v_topic_id
  from rgsr.forum_topics
  where slug = p_topic_slug and is_active = true;

  if v_topic_id is null then
    raise exception 'INVALID_TOPIC' using errcode='22023';
  end if;

  v_title := btrim(coalesce(p_title,''));
  v_body  := btrim(coalesce(p_body,''));

  -- conservative default; your profanity/filter logic can be layered inside later
  v_ok := (length(v_title) >= 3 and length(v_body) >= 20);
  if not v_ok then v_reason := 'TOO_SHORT'; end if;

  insert into rgsr.forum_posts (
    post_id, created_by, created_at, updated_at,
    is_approved, approved_at,
    topic_id, title, body, tags, metadata, rejected_reason
  ) values (
    gen_random_uuid(), v_uid, now(), now(),
    v_ok, case when v_ok then now() else null end,
    v_topic_id, v_title, v_body, coalesce(p_tags,'{}'::text[]),
    jsonb_build_object('auto_moderated', true),
    v_reason
  )
  returning post_id into v_post_id;

  return v_post_id;
end
$fn$;

alter function rgsr.submit_forum_post(text,text,text,text[]) set search_path = rgsr, public;

-- ------------------------------------------------------------
-- 3) submit_research_upload (SECURITY INVOKER)
-- ------------------------------------------------------------
create function rgsr.submit_research_upload(
  p_title text,
  p_body text,
  p_tags text[] default '{}'::text[]
) returns uuid
language plpgsql
security invoker
as $fn$
declare
  v_uid uuid;
  v_ok boolean;
  v_reason text;
  v_title text;
  v_body text;
  v_id uuid;
begin
  v_uid := rgsr.actor_uid();
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode='28000';
  end if;

  v_title := btrim(coalesce(p_title,''));
  v_body  := btrim(coalesce(p_body,''));

  v_ok := (length(v_title) >= 3 and length(v_body) >= 20);
  if not v_ok then v_reason := 'TOO_SHORT'; end if;

  insert into rgsr.research_uploads (
    research_id, created_by, created_at, updated_at,
    is_approved, approved_at,
    title, body, tags, metadata, rejected_reason
  ) values (
    gen_random_uuid(), v_uid, now(), now(),
    v_ok, case when v_ok then now() else null end,
    v_title, v_body, coalesce(p_tags,'{}'::text[]),
    jsonb_build_object('auto_moderated', true),
    v_reason
  )
  returning research_id into v_id;

  return v_id;
end
$fn$;

alter function rgsr.submit_research_upload(text,text,text[]) set search_path = rgsr, public;

-- ------------------------------------------------------------
-- 4) list RPCs (UI-safe)
-- ------------------------------------------------------------
create function rgsr.list_forum_posts(
  p_topic_slug text default null,
  p_tag text default null,
  p_search text default null,
  p_limit int default 50,
  p_offset int default 0
) returns jsonb
language sql
stable
security invoker
as $fn$
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb),
    'limit', p_limit,
    'offset', p_offset
  )
  from (
    select
      fp.post_id,
      fp.created_by,
      fp.created_at,
      fp.updated_at,
      fp.is_approved,
      fp.approved_at,
      ft.slug as topic_slug,
      ft.title as topic_title,
      fp.title,
      fp.body,
      fp.tags,
      fp.metadata
    from rgsr.forum_posts fp
    join rgsr.forum_topics ft on ft.topic_id = fp.topic_id
    where (p_topic_slug is null or ft.slug = p_topic_slug)
      and (p_tag is null or p_tag = any(fp.tags))
      and (
        p_search is null
        or fp.title ilike ('%'||p_search||'%')
        or fp.body  ilike ('%'||p_search||'%')
      )
    order by fp.created_at desc
    limit greatest(1, least(p_limit, 200))
    offset greatest(0, p_offset)
  ) x;
$fn$;

alter function rgsr.list_forum_posts(text,text,text,int,int) set search_path = rgsr, public;

create function rgsr.list_research_uploads(
  p_tag text default null,
  p_search text default null,
  p_limit int default 50,
  p_offset int default 0
) returns jsonb
language sql
stable
security invoker
as $fn$
  select jsonb_build_object(
    'items', coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb),
    'limit', p_limit,
    'offset', p_offset
  )
  from (
    select
      ru.research_id,
      ru.created_by,
      ru.created_at,
      ru.updated_at,
      ru.is_approved,
      ru.approved_at,
      ru.title,
      ru.body,
      ru.tags,
      ru.metadata
    from rgsr.research_uploads ru
    where (p_tag is null or p_tag = any(ru.tags))
      and (
        p_search is null
        or ru.title ilike ('%'||p_search||'%')
        or ru.body  ilike ('%'||p_search||'%')
      )
    order by ru.created_at desc
    limit greatest(1, least(p_limit, 200))
    offset greatest(0, p_offset)
  ) x;
$fn$;

alter function rgsr.list_research_uploads(text,text,int,int) set search_path = rgsr, public;

-- ------------------------------------------------------------
-- 5) Grants
-- ------------------------------------------------------------
do $do$
begin
  grant execute on function rgsr.actor_uid() to anon, authenticated;

  grant execute on function rgsr.list_forum_posts(text,text,text,int,int) to anon, authenticated;
  grant execute on function rgsr.list_research_uploads(text,text,int,int) to anon, authenticated;

  grant execute on function rgsr.submit_forum_post(text,text,text,text[]) to authenticated;
  grant execute on function rgsr.submit_research_upload(text,text,text[]) to authenticated;
end
$do$;

commit;

-- Manual test:
-- select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111', true);
-- select set_config('request.jwt.claim.role','authenticated', true);
-- select rgsr.actor_uid();
-- select rgsr.submit_forum_post('how-to','Test title','This is a test body with enough length.', array['runs']);
-- select rgsr.list_forum_posts('how-to', null, null, 10, 0);
'@

WriteUtf8NoBom $mgPath $sql
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

Write-Host "✅ v11.3.1 applied (drop+recreate RPCs)" -ForegroundColor Green
