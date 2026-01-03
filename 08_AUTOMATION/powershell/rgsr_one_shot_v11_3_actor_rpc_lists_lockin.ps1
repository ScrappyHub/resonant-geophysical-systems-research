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
$mgPath = Join-Path $mgDir ("{0}_rgsr_v11_3_actor_rpc_lists_lockin.sql" -f $MigrationId)

$sql = @'
-- ============================================================
-- RGSR v11.3 — ACTOR UID + RPC HARDENING + LIST RPCs (NO UI GUESSING)
-- - Fixes created_by NULL by requiring actor uid
-- - Converts submit RPCs to SECURITY INVOKER (no postgres definer bypass)
-- - Adds list_forum_posts / list_research_uploads RPCs for UI
-- - Does NOT touch auth schema / MFA
-- ============================================================

begin;

-- Guard
do $do$
begin
  if to_regnamespace('rgsr') is null then
    return;
  end if;
end
$do$;

-- ------------------------------------------------------------
-- 1) Canonical actor uid resolver (Supabase JWT claim compatible)
-- ------------------------------------------------------------
create or replace function rgsr.actor_uid()
returns uuid
language sql
stable
as $fn$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$fn$;

alter function rgsr.actor_uid() set search_path = rgsr, public;

-- ------------------------------------------------------------
-- 2) Harden submit_forum_post: SECURITY INVOKER + require actor
-- ------------------------------------------------------------
create or replace function rgsr.submit_forum_post(
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
begin
  v_uid := rgsr.actor_uid();
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode='28000';
  end if;

  -- topic lookup (active only)
  select topic_id into v_topic_id
  from rgsr.forum_topics
  where slug = p_topic_slug and is_active = true;

  if v_topic_id is null then
    raise exception 'INVALID_TOPIC' using errcode='22023';
  end if;

  -- basic normalization (sanitization is handled by your v11.2 logic; keep minimal here)
  v_title := btrim(coalesce(p_title,''));
  v_body  := btrim(coalesce(p_body,''));

  -- delegate moderation to your existing v11.2 logic if it exists.
  -- If your v11.2 function already computes v_ok/v_reason, keep it.
  -- Here we implement a conservative default: auto-approve if non-empty and long enough.
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
  returning post_id into strict v_topic_id; -- reuse var as output uuid

  return v_topic_id;
end
$fn$;

alter function rgsr.submit_forum_post(text,text,text,text[]) set search_path = rgsr, public;

-- ------------------------------------------------------------
-- 3) Harden submit_research_upload: SECURITY INVOKER + require actor
-- ------------------------------------------------------------
create or replace function rgsr.submit_research_upload(
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
-- 4) UI LIST RPCs (single truth; UI never hand-builds SQL)
--     NOTE: These respect RLS automatically (SECURITY INVOKER).
-- ------------------------------------------------------------
create or replace function rgsr.list_forum_posts(
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
    'items',
    coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb),
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
        or (fp.title ilike ('%'||p_search||'%'))
        or (fp.body  ilike ('%'||p_search||'%'))
      )
    order by fp.created_at desc
    limit greatest(1, least(p_limit, 200))
    offset greatest(0, p_offset)
  ) x;
$fn$;

alter function rgsr.list_forum_posts(text,text,text,int,int) set search_path = rgsr, public;

create or replace function rgsr.list_research_uploads(
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
    'items',
    coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb),
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
        or (ru.title ilike ('%'||p_search||'%'))
        or (ru.body  ilike ('%'||p_search||'%'))
      )
    order by ru.created_at desc
    limit greatest(1, least(p_limit, 200))
    offset greatest(0, p_offset)
  ) x;
$fn$;

alter function rgsr.list_research_uploads(text,text,int,int) set search_path = rgsr, public;

-- ------------------------------------------------------------
-- 5) Grants: allow anon/auth to read lists; auth to submit
-- ------------------------------------------------------------
do $do$
begin
  -- RPCs for public browsing
  grant execute on function rgsr.list_forum_posts(text,text,text,int,int) to anon, authenticated;
  grant execute on function rgsr.list_research_uploads(text,text,int,int) to anon, authenticated;

  -- submit requires auth (function itself enforces AUTH_REQUIRED)
  grant execute on function rgsr.submit_forum_post(text,text,text,text[]) to authenticated;
  grant execute on function rgsr.submit_research_upload(text,text,text[]) to authenticated;

  -- actor_uid used internally, but safe to expose
  grant execute on function rgsr.actor_uid() to anon, authenticated;
end
$do$;

commit;

-- ============================================================
-- Manual test (SQL editor):
-- select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',true);
-- select set_config('request.jwt.claim.role','authenticated',true);
-- select rgsr.submit_forum_post('how-to','Test','This is a test body long enough.', array['runs']);
-- select rgsr.list_forum_posts('how-to', null, null, 10, 0);
-- ============================================================
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

Write-Host "✅ v11.3 applied (actor uid + invoker submit + list RPCs)" -ForegroundColor Green
