param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
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
if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) { throw "supabase CLI not found in PATH." }

$mgDir = Join-Path $RepoRoot "supabase\migrations"
EnsureDir $mgDir

$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_v12_2_cloud_projects_publish_vetted.sql" -f $MigrationId)

$sql = @'
-- ============================================================
-- RGSR v12.2 — CLOUD PROJECTS + PUBLISH + VETTED GATING (NO PII)
-- CORE-compatible: governance + social proof + policy/RLS + flags
-- - Cloud storage bucket + RLS quota gating
-- - Projects + saved states (snapshots)
-- - Publish-to-public submission workflow (team credits without names)
-- - Vetted member rule: after 5 approved submissions => auto-approve posts/uploads
-- ============================================================
begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 0) Storage bucket (Supabase Storage)
--     - Private bucket for project saves/assets
-- ------------------------------------------------------------
do $do$
begin
  -- storage schema exists in Supabase; this does not modify auth.*
  if exists (select 1 from pg_namespace where nspname='storage') then
    insert into storage.buckets(id, name, public)
    values ('rgsr_projects','rgsr_projects', false)
    on conflict (id) do update set name=excluded.name, public=false;
  end if;
end
$do$;

-- ------------------------------------------------------------
-- 1) Canonical helpers: vetted + entitlements + quota
-- ------------------------------------------------------------

-- count approved "social proof" submissions (forum + research + publish approvals)
create or replace function rgsr.approved_submission_count(p_uid uuid)
returns bigint
language sql
stable
as $fn$
  select
    coalesce((select count(*) from rgsr.forum_posts fp where fp.created_by=p_uid and fp.is_approved=true),0)
  + coalesce((select count(*) from rgsr.research_uploads ru where ru.created_by=p_uid and ru.is_approved=true),0)
  + coalesce((select count(*) from rgsr.publish_submissions ps where ps.submitted_by=p_uid and ps.status='approved'),0);
$fn$;

create or replace function rgsr.is_vetted(p_uid uuid)
returns boolean
language sql
stable
as $fn$
  select (rgsr.approved_submission_count(p_uid) >= 5);
$fn$;

-- entitlement: CLOUD_STORAGE_GB stored as {"gb":20} (or {"value":20})
create or replace function rgsr.cloud_storage_limit_bytes(p_uid uuid)
returns bigint
language sql
stable
as $fn$
  with e as (
    select entitlement_value
    from rgsr.entitlements
    where owner_uid=p_uid
      and entitlement_key='CLOUD_STORAGE_GB'
      and active=true
      and (ends_at is null or ends_at > now())
    order by updated_at desc
    limit 1
  )
  select
    (coalesce(
      nullif((select (entitlement_value->>'gb')::bigint from e), null),
      nullif((select (entitlement_value->>'value')::bigint from e), null),
      1::bigint
    ) * 1024 * 1024 * 1024);
$fn$;

-- storage used bytes from storage.objects.metadata.size (best-effort)
create or replace function rgsr.cloud_storage_used_bytes(p_uid uuid)
returns bigint
language sql
stable
security definer
set search_path = public, pg_catalog, rgsr, storage
as $fn$
  select coalesce(sum(coalesce((o.metadata->>'size')::bigint, 0)), 0)
  from storage.objects o
  where o.bucket_id='rgsr_projects'
    and o.owner = p_uid;
$fn$;

create or replace function rgsr.cloud_storage_can_add(p_uid uuid, p_add_bytes bigint)
returns boolean
language sql
stable
security definer
set search_path = public, pg_catalog, rgsr, storage
as $fn$
  select (rgsr.cloud_storage_used_bytes(p_uid) + greatest(coalesce(p_add_bytes,0),0) <= rgsr.cloud_storage_limit_bytes(p_uid));
$fn$;

-- ------------------------------------------------------------
-- 2) Projects + Snapshots (saved states)
-- ------------------------------------------------------------
create table if not exists rgsr.projects (
  project_id uuid primary key default gen_random_uuid(),
  owner_uid uuid not null references auth.users(id) on delete restrict,

  title text not null,
  summary text not null default '',
  tags text[] not null default '{}'::text[],

  engine_mode text not null default '3d', -- '2d'|'3d'|'hybrid'
  is_public boolean not null default false,
  public_slug text null,

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint projects_engine_mode_chk check (engine_mode in ('2d','3d','hybrid')),
  constraint projects_title_len_chk check (length(btrim(title)) between 3 and 120)
);

create unique index if not exists ux_projects_owner_slug
on rgsr.projects(owner_uid, public_slug)
where public_slug is not null;

create table if not exists rgsr.project_snapshots (
  snapshot_id uuid primary key default gen_random_uuid(),
  project_id uuid not null references rgsr.projects(project_id) on delete cascade,
  owner_uid uuid not null references auth.users(id) on delete restrict,

  -- points to storage.objects.name in bucket 'rgsr_projects'
  object_path text not null,

  phase text not null default 'draft', -- draft/alpha/beta/release
  version_label text not null default '',
  size_bytes bigint not null default 0,

  -- snapshot content should be stored in Storage; DB keeps metadata only
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),

  constraint snapshots_phase_chk check (phase in ('draft','alpha','beta','release')),
  constraint snapshots_path_chk check (length(btrim(object_path)) >= 5)
);

create index if not exists ix_snapshots_project_time on rgsr.project_snapshots(project_id, created_at desc);
create index if not exists ix_snapshots_owner_time on rgsr.project_snapshots(owner_uid, created_at desc);

-- ------------------------------------------------------------
-- 3) Public identities (NO REAL NAMES)
--     - Generated handle per submission category
-- ------------------------------------------------------------
create table if not exists rgsr.public_identities (
  identity_id uuid primary key default gen_random_uuid(),
  owner_uid uuid not null references auth.users(id) on delete restrict,

  identity_kind text not null, -- e.g. 'hydro','systems','acoustics','coupling','geology'
  display_handle text not null,

  created_at timestamptz not null default now(),

  constraint identity_kind_chk check (length(btrim(identity_kind)) between 3 and 32),
  constraint identity_handle_chk check (length(btrim(display_handle)) between 6 and 64),
  constraint ux_identity_kind_handle unique (identity_kind, display_handle)
);

create or replace function rgsr.make_public_handle(p_kind text)
returns text
language plpgsql
volatile
as $fn$
declare
  v_kind text := regexp_replace(lower(coalesce(p_kind,'')),'[^a-z0-9]+','','g');
  v_try text;
  v_n int;
begin
  if length(v_kind) < 3 then
    v_kind := 'research';
  end if;

  -- try a few random suffixes to avoid collisions
  for v_n in 1..20 loop
    v_try := initcap(v_kind) || 'Researcher' || (floor(random()*9000)+1000)::int::text;
    begin
      perform 1 from rgsr.public_identities where identity_kind=v_kind and display_handle=v_try;
      if not found then
        return v_try;
      end if;
    exception when others then
      null;
    end;
  end loop;

  -- final fallback
  return initcap(v_kind) || 'Researcher' || (extract(epoch from now())::bigint % 100000)::text;
end
$fn$;

create or replace function rgsr.ensure_public_identity(p_kind text)
returns jsonb
language plpgsql
security invoker
as $fn$
declare
  v_uid uuid;
  v_kind text;
  v_handle text;
  v_id uuid;
begin
  v_uid := rgsr.actor_uid();
  if v_uid is null then
    raise exception 'AUTH_REQUIRED' using errcode='28000';
  end if;

  v_kind := regexp_replace(lower(coalesce(p_kind,'')),'[^a-z0-9]+','','g');
  if length(v_kind) < 3 then v_kind := 'research'; end if;

  -- if caller already has an identity for this kind, reuse the latest
  select identity_id, display_handle into v_id, v_handle
  from rgsr.public_identities
  where owner_uid=v_uid and identity_kind=v_kind
  order by created_at desc
  limit 1;

  if v_id is null then
    v_handle := rgsr.make_public_handle(v_kind);
    insert into rgsr.public_identities(owner_uid, identity_kind, display_handle)
    values (v_uid, v_kind, v_handle)
    returning identity_id into v_id;
  end if;

  return jsonb_build_object('ok',true,'identity_id',v_id,'identity_kind',v_kind,'display_handle',v_handle);
end
$fn$;

grant execute on function rgsr.ensure_public_identity(text) to authenticated;

-- ------------------------------------------------------------
-- 4) Publish-to-public submissions (submission form)
--     - NO real names; credits are aliases/roles only
-- ------------------------------------------------------------
create table if not exists rgsr.publish_submissions (
  submission_id uuid primary key default gen_random_uuid(),
  project_id uuid not null references rgsr.projects(project_id) on delete cascade,
  owner_uid uuid not null references auth.users(id) on delete restrict,

  submitted_by uuid not null references auth.users(id) on delete restrict,
  submitted_at timestamptz not null default now(),

  -- publish form inputs
  phase text not null default 'draft',
  submission_kind text not null default 'systems', -- affects public handle category
  notes text not null default '',

  -- moderation state
  status text not null default 'pending', -- pending/approved/rejected
  reviewed_by uuid null references auth.users(id) on delete set null,
  reviewed_at timestamptz null,
  rejection_reason text null,

  -- on approval we pin a public handle + listing snapshot
  identity_id uuid null references rgsr.public_identities(identity_id) on delete set null,
  public_listing jsonb not null default '{}'::jsonb,

  metadata jsonb not null default '{}'::jsonb,

  constraint publish_phase_chk check (phase in ('draft','alpha','beta','release')),
  constraint publish_status_chk check (status in ('pending','approved','rejected')),
  constraint publish_kind_chk check (length(btrim(submission_kind)) between 3 and 32)
);

create index if not exists ix_publish_owner_time on rgsr.publish_submissions(owner_uid, submitted_at desc);
create index if not exists ix_publish_project_time on rgsr.publish_submissions(project_id, submitted_at desc);

create table if not exists rgsr.publish_credits (
  credit_id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references rgsr.publish_submissions(submission_id) on delete cascade,

  -- team credit WITHOUT names: role + optional org/lab slug if they opted in
  credit_role text not null,             -- e.g. 'Lead','Contributor','Reviewer'
  credit_alias text not null,            -- e.g. 'HydroCouplingResearcher52' or 'CORE_Lab_01' (opt-in)
  credit_scope text not null default 'team', -- team/lab/institution

  sort_order int not null default 10,

  constraint credit_role_len check (length(btrim(credit_role)) between 2 and 40),
  constraint credit_alias_len check (length(btrim(credit_alias)) between 3 and 64),
  constraint credit_scope_chk check (credit_scope in ('team','lab','institution'))
);

create index if not exists ix_publish_credits_submission on rgsr.publish_credits(submission_id, sort_order);

-- ------------------------------------------------------------
-- 5) Vetted gating: forum + research auto-approval after 5 approvals
--     - Still sanitized + profanity filtered by existing checks/policies
-- ------------------------------------------------------------
create or replace function rgsr.compute_auto_approve(p_uid uuid, p_ok boolean)
returns boolean
language sql
stable
as $fn$
  select (p_ok is true) and rgsr.is_vetted(p_uid);
$fn$;

-- NOTE: We only adjust the RPCs; table policies remain your guard rails.
-- If your existing v11.x RPCs are present, we replace them to enforce vetted logic.

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
  v_is_approved boolean;
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

  -- conservative minimums; your policies enforce sanitize/profanity
  v_ok := (length(v_title) >= 3 and length(v_body) >= 20);
  if not v_ok then v_reason := 'TOO_SHORT'; end if;

  v_is_approved := rgsr.compute_auto_approve(v_uid, v_ok);

  insert into rgsr.forum_posts (
    post_id, created_by, created_at, updated_at,
    is_approved, approved_at,
    topic_id, title, body, tags, metadata, rejected_reason
  ) values (
    gen_random_uuid(), v_uid, now(), now(),
    v_is_approved, case when v_is_approved then now() else null end,
    v_topic_id, v_title, v_body, coalesce(p_tags,'{}'::text[]),
    jsonb_build_object('auto_moderated', true, 'vetted', rgsr.is_vetted(v_uid)),
    case when v_ok then null else v_reason end
  )
  returning post_id into v_post_id;

  return v_post_id;
end
$fn$;

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
  v_is_approved boolean;
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

  v_is_approved := rgsr.compute_auto_approve(v_uid, v_ok);

  insert into rgsr.research_uploads(
    research_id, created_by, created_at, updated_at,
    is_approved, approved_at,
    title, body, tags, metadata, rejected_reason
  ) values (
    gen_random_uuid(), v_uid, now(), now(),
    v_is_approved, case when v_is_approved then now() else null end,
    v_title, v_body, coalesce(p_tags,'{}'::text[]),
    jsonb_build_object('auto_moderated', true, 'vetted', rgsr.is_vetted(v_uid)),
    case when v_ok then null else v_reason end
  )
  returning research_id into v_id;

  return v_id;
end
$fn$;

-- ------------------------------------------------------------
-- 6) RLS ENABLE + FORCE (new tables)
-- ------------------------------------------------------------
alter table rgsr.projects enable row level security;
alter table rgsr.project_snapshots enable row level security;
alter table rgsr.public_identities enable row level security;
alter table rgsr.publish_submissions enable row level security;
alter table rgsr.publish_credits enable row level security;

alter table rgsr.projects force row level security;
alter table rgsr.project_snapshots force row level security;
alter table rgsr.public_identities force row level security;
alter table rgsr.publish_submissions force row level security;
alter table rgsr.publish_credits force row level security;

-- ------------------------------------------------------------
-- 7) Drop existing policies on these tables (avoid union leakage)
-- ------------------------------------------------------------
do $do$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname='rgsr'
      and tablename in ('projects','project_snapshots','public_identities','publish_submissions','publish_credits')
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end
$do$;

-- ------------------------------------------------------------
-- 8) Canonical policies
-- ------------------------------------------------------------

-- projects
create policy projects_read_public on rgsr.projects
for select to anon, authenticated
using (is_public = true);

create policy projects_read_own on rgsr.projects
for select to authenticated
using (owner_uid = rgsr.actor_uid());

create policy projects_write_own on rgsr.projects
for insert, update, delete to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

create policy projects_admin on rgsr.projects
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- snapshots (owner only; public handled via publish listing, not raw storage)
create policy snapshots_read_own on rgsr.project_snapshots
for select to authenticated
using (owner_uid = rgsr.actor_uid());

create policy snapshots_write_own on rgsr.project_snapshots
for insert, update, delete to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

create policy snapshots_admin on rgsr.project_snapshots
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- identities
create policy identities_read_own on rgsr.public_identities
for select to authenticated
using (owner_uid = rgsr.actor_uid());

create policy identities_write_own on rgsr.public_identities
for insert, delete to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

create policy identities_admin on rgsr.public_identities
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- publish submissions
create policy publish_read_public on rgsr.publish_submissions
for select to anon, authenticated
using (status='approved');

create policy publish_read_own on rgsr.publish_submissions
for select to authenticated
using (owner_uid = rgsr.actor_uid());

create policy publish_insert_own on rgsr.publish_submissions
for insert to authenticated
with check (owner_uid = rgsr.actor_uid() and submitted_by = rgsr.actor_uid());

create policy publish_update_own_pending on rgsr.publish_submissions
for update to authenticated
using (owner_uid = rgsr.actor_uid() and status='pending')
with check (owner_uid = rgsr.actor_uid() and status='pending');

create policy publish_admin on rgsr.publish_submissions
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- publish credits: visible if submission approved OR owner
create policy credits_read_public on rgsr.publish_credits
for select to anon, authenticated
using (
  exists (
    select 1 from rgsr.publish_submissions ps
    where ps.submission_id = publish_credits.submission_id
      and ps.status='approved'
  )
);

create policy credits_read_owner on rgsr.publish_credits
for select to authenticated
using (
  exists (
    select 1 from rgsr.publish_submissions ps
    where ps.submission_id = publish_credits.submission_id
      and ps.owner_uid = rgsr.actor_uid()
  )
);

create policy credits_write_owner_pending on rgsr.publish_credits
for insert, update, delete to authenticated
using (
  exists (
    select 1 from rgsr.publish_submissions ps
    where ps.submission_id = publish_credits.submission_id
      and ps.owner_uid = rgsr.actor_uid()
      and ps.status='pending'
  )
)
with check (
  exists (
    select 1 from rgsr.publish_submissions ps
    where ps.submission_id = publish_credits.submission_id
      and ps.owner_uid = rgsr.actor_uid()
      and ps.status='pending'
  )
);

create policy credits_admin on rgsr.publish_credits
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- ------------------------------------------------------------
-- 9) Storage RLS (bucket rgsr_projects)
--     - user can only see/modify their own objects (storage.objects.owner)
--     - insert allowed only if within quota (CLOUD_STORAGE_GB entitlement)
-- ------------------------------------------------------------
do $do$
begin
  if exists (select 1 from pg_namespace where nspname='storage') then

    -- enable + force RLS on storage.objects is handled by Supabase;
    -- we add bucket-scoped policies.

    -- drop old bucket policies (if any)
    perform 1;
    -- best-effort drops; ignore if not present
    execute 'drop policy if exists rgsr_projects_read_own on storage.objects';
    execute 'drop policy if exists rgsr_projects_write_own on storage.objects';
    execute 'drop policy if exists rgsr_projects_admin on storage.objects';

    -- read own objects
    execute $q$
      create policy rgsr_projects_read_own on storage.objects
      for select to authenticated
      using (bucket_id='rgsr_projects' and owner = auth.uid())
    $q$;

    -- write own objects, quota gated
    execute $q$
      create policy rgsr_projects_write_own on storage.objects
      for insert, update, delete to authenticated
      using (bucket_id='rgsr_projects' and owner = auth.uid())
      with check (
        bucket_id='rgsr_projects'
        and owner = auth.uid()
        and rgsr.cloud_storage_can_add(auth.uid(), coalesce((metadata->>'size')::bigint, 0))
      )
    $q$;

    -- admin override
    execute $q$
      create policy rgsr_projects_admin on storage.objects
      for all to authenticated
      using (rgsr.can_write())
      with check (rgsr.can_write())
    $q$;

  end if;
end
$do$;

commit;

-- ============================================================
-- Manual verification (SQL editor):
-- 1) select rgsr.approved_submission_count(rgsr.actor_uid());
-- 2) select rgsr.is_vetted(rgsr.actor_uid());
-- 3) select rgsr.cloud_storage_limit_bytes(rgsr.actor_uid()), rgsr.cloud_storage_used_bytes(rgsr.actor_uid());
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

Write-Host "✅ v12.2 applied (cloud projects + publish + vetted + storage quota)" -ForegroundColor Green
