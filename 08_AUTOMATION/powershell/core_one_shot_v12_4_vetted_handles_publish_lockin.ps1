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
  Write-Host ("[OK] WROTE " + $Path) -ForegroundColor Green
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

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) { throw "supabase CLI not found in PATH." }

$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_v12_4_vetted_handles_publish.sql" -f $MigrationId)

$sql = @'
-- ============================================================
-- CORE / RGSR v12.4 — VETTED + ROTATING PUBLIC HANDLES + PUBLISH FLOW
-- - NO real names; no emails/phones/passwords stored
-- - Vetted after 5 APPROVED submissions across: forum + research + publish
-- - After vetted: auto-approve future submissions (still sanitized/profanity-gated)
-- - Rotating handle: generated per submission (not stable; cannot be tracked)
-- ============================================================

begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 1) Public handle generator (rotating)
-- ------------------------------------------------------------
create sequence if not exists rgsr.public_handle_seq;

create or replace function rgsr.normalize_handle_domain(p text)
returns text
language sql
immutable
as $fn$
  select
    case
      when p is null or length(btrim(p)) = 0 then 'Systems'
      else
        -- keep letters only, title-ish casing by stripping non-letters
        -- (no extension required; keep simple + safe)
        initcap(regexp_replace(btrim(p), '[^A-Za-z]+', '', 'g'))
    end;
$fn$;

create or replace function rgsr.generate_public_handle(p_domain text)
returns text
language plpgsql
volatile
as $fn$
declare
  v_dom text;
  v_n bigint;
begin
  v_dom := rgsr.normalize_handle_domain(p_domain);
  v_n := nextval('rgsr.public_handle_seq');
  return v_dom || 'Researcher' || (v_n % 100000)::text;
end
$fn$;

-- ------------------------------------------------------------
-- 2) Vetted rule: >= 5 approved submissions
-- ------------------------------------------------------------
create or replace function rgsr.approved_submission_count(p_uid uuid)
returns bigint
language sql
stable
as $fn$
  select
    coalesce((select count(*) from rgsr.forum_posts fp
             where fp.created_by=p_uid and fp.is_approved=true),0)
  + coalesce((select count(*) from rgsr.research_uploads ru
             where ru.created_by=p_uid and ru.is_approved=true),0)
  + coalesce((select count(*) from rgsr.publish_submissions ps
             where ps.submitted_by=p_uid and ps.status='approved'),0);
$fn$;

create or replace function rgsr.is_vetted(p_uid uuid)
returns boolean
language sql
stable
as $fn$
  select rgsr.approved_submission_count(p_uid) >= 5;
$fn$;

-- ------------------------------------------------------------
-- 3) Add per-row rotating handle columns (if missing)
-- ------------------------------------------------------------
alter table rgsr.forum_posts
  add column if not exists public_handle text;

alter table rgsr.research_uploads
  add column if not exists public_handle text;

alter table rgsr.publish_submissions
  add column if not exists public_handle text;

create index if not exists ix_forum_posts_public_handle on rgsr.forum_posts(public_handle);
create index if not exists ix_research_uploads_public_handle on rgsr.research_uploads(public_handle);
create index if not exists ix_publish_submissions_public_handle on rgsr.publish_submissions(public_handle);

-- ------------------------------------------------------------
-- 4) Canonical submit_forum_post: vetted => auto-approve; else pending
--     Still MUST pass sanitize + profanity filters via existing RLS checks.
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
  v_handle text;
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

  -- base validity
  v_ok := (length(v_title) >= 3 and length(v_body) >= 20);
  if not v_ok then v_reason := 'TOO_SHORT'; end if;

  -- vetted => approved; otherwise pending (still stored, but not public)
  if v_ok and rgsr.is_vetted(v_uid) then
    v_ok := true;
  else
    v_ok := false;
  end if;

  -- rotating handle per submission: domain chosen from topic slug
  v_handle := rgsr.generate_public_handle(p_topic_slug);

  insert into rgsr.forum_posts (
    post_id, created_by, created_at, updated_at,
    is_approved, approved_at,
    topic_id, title, body, tags, metadata, rejected_reason,
    public_handle
  ) values (
    gen_random_uuid(), v_uid, now(), now(),
    v_ok, case when v_ok then now() else null end,
    v_topic_id, v_title, v_body, coalesce(p_tags,'{}'::text[]),
    jsonb_build_object('auto_moderated', true, 'vetted', rgsr.is_vetted(v_uid)),
    v_reason,
    v_handle
  )
  returning post_id into v_post_id;

  return v_post_id;
end
$fn$;

-- ------------------------------------------------------------
-- 5) Canonical submit_research_upload: vetted => auto-approve; else pending
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
  v_domain text;
  v_handle text;
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

  if v_ok and rgsr.is_vetted(v_uid) then
    v_ok := true;
  else
    v_ok := false;
  end if;

  -- derive domain from first tag if present; else Systems
  v_domain := coalesce(nullif((coalesce(p_tags,'{}'::text[]))[1],''), 'Systems');
  v_handle := rgsr.generate_public_handle(v_domain);

  insert into rgsr.research_uploads (
    research_id, created_by, created_at, updated_at,
    is_approved, approved_at,
    title, body, tags, metadata, rejected_reason,
    public_handle
  ) values (
    gen_random_uuid(), v_uid, now(), now(),
    v_ok, case when v_ok then now() else null end,
    v_title, v_body, coalesce(p_tags,'{}'::text[]),
    jsonb_build_object('auto_moderated', true, 'vetted', rgsr.is_vetted(v_uid)),
    v_reason,
    v_handle
  )
  returning research_id into v_id;

  return v_id;
end
$fn$;

-- ------------------------------------------------------------
-- 6) Publish submission RPC (submission form)
--     - status: approved if vetted, else pending
--     - rotating handle per submission based on project vertical/domain
-- ------------------------------------------------------------
create or replace function rgsr.submit_publish_submission(
  p_project_id uuid,
  p_phase text,
  p_title text,
  p_summary text,
  p_tags text[] default '{}'::text[],
  p_credit_ids uuid[] default '{}'::uuid[]
) returns uuid
language plpgsql
security invoker
as $fn$
declare
  v_uid uuid;
  v_status text;
  v_domain text;
  v_handle text;
  v_submission_id uuid;
begin
  v_uid := rgsr.actor_uid();
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode='28000';
  end if;

  -- user must own the project (projects RLS already enforces; also check)
  perform 1 from rgsr.projects p where p.project_id = p_project_id and p.owner_uid = v_uid;
  if not found then
    raise exception 'PROJECT_NOT_OWNED' using errcode='42501';
  end if;

  if rgsr.is_vetted(v_uid) then
    v_status := 'approved';
  else
    v_status := 'pending';
  end if;

  v_domain := coalesce(nullif((coalesce(p_tags,'{}'::text[]))[1],''), 'Systems');
  v_handle := rgsr.generate_public_handle(v_domain);

  insert into rgsr.publish_submissions (
    submission_id,
    project_id,
    submitted_by,
    status,
    phase,
    title,
    summary,
    tags,
    credit_ids,
    public_handle,
    created_at,
    updated_at,
    metadata
  ) values (
    gen_random_uuid(),
    p_project_id,
    v_uid,
    v_status,
    btrim(coalesce(p_phase,'')),
    btrim(coalesce(p_title,'')),
    btrim(coalesce(p_summary,'')),
    coalesce(p_tags,'{}'::text[]),
    coalesce(p_credit_ids,'{}'::uuid[]),
    v_handle,
    now(),
    now(),
    jsonb_build_object('vetted', rgsr.is_vetted(v_uid))
  )
  returning submission_id into v_submission_id;

  return v_submission_id;
end
$fn$;

-- ------------------------------------------------------------
-- 7) Grants (minimal; RLS is the gate)
-- ------------------------------------------------------------
do $do$
begin
  revoke all on schema rgsr from public;
  grant usage on schema rgsr to anon;
  grant usage on schema rgsr to authenticated;
  grant usage on schema rgsr to service_role;
end
$do$;

commit;

-- ============================================================
-- Manual verification (SQL):
-- select rgsr.approved_submission_count(rgsr.actor_uid());
-- select rgsr.is_vetted(rgsr.actor_uid());
-- select rgsr.submit_forum_post('how-to','Test title','This is a test body with enough length.', array['runs','layers']);
-- select rgsr.submit_research_upload('Test research','Research body long enough to pass checks.', array['hydro','acoustics']);
-- ============================================================
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

Write-Host "✅ v12.4 LOCKED-IN (VETTED + ROTATING HANDLES + PUBLISH FLOW)" -ForegroundColor Green
