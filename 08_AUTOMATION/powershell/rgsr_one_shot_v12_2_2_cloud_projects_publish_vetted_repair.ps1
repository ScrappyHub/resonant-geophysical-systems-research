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
$dead  = Join-Path $RepoRoot "supabase\migrations_disabled"
EnsureDir $mgDir
EnsureDir $dead

Write-Host ("[INFO] RepoRoot=" + $RepoRoot) -ForegroundColor Gray
Write-Host ("[INFO] mgDir=" + $mgDir) -ForegroundColor Gray
Write-Host ("[INFO] deadDir=" + $dead) -ForegroundColor Gray

# ------------------------------------------------------------
# 0) Disable the broken v12.2.1 migration file if present
# ------------------------------------------------------------
$bad = @(Get-ChildItem -LiteralPath $mgDir -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -Like "*_rgsr_v12_2_1_cloud_projects_publish_vetted_repair.sql" })

if ($bad.Count -gt 0) {
  foreach ($f in $bad) {
    Move-Item -LiteralPath $f.FullName -Destination $dead -Force
    Write-Host ("[OK] Disabled broken migration -> " + (Join-Path $dead $f.Name)) -ForegroundColor DarkYellow
  }
} else {
  Write-Host "[INFO] No v12.2.1 repair migration file found to disable." -ForegroundColor Gray
}

# ------------------------------------------------------------
# 1) Write v12.2.2 repair migration: create tables + VALID policies
# ------------------------------------------------------------
$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_v12_2_2_cloud_projects_publish_vetted_repair.sql" -f $MigrationId)

$sql = @'
-- ============================================================
-- RGSR v12.2.2 — REPAIR: CLOUD PROJECTS + PUBLISH + VETTED (NO PII)
-- Fix: Postgres policies cannot be "FOR insert, update, delete".
-- Use separate policies per command (or FOR ALL).
-- ============================================================
begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 1) Tables (idempotent)
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

  object_path text not null,
  phase text not null default 'draft', -- draft/alpha/beta/release
  version_label text not null default '',
  size_bytes bigint not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),

  constraint snapshots_phase_chk check (phase in ('draft','alpha','beta','release')),
  constraint snapshots_path_chk check (length(btrim(object_path)) >= 5)
);

create index if not exists ix_snapshots_project_time on rgsr.project_snapshots(project_id, created_at desc);
create index if not exists ix_snapshots_owner_time on rgsr.project_snapshots(owner_uid, created_at desc);

create table if not exists rgsr.public_identities (
  identity_id uuid primary key default gen_random_uuid(),
  owner_uid uuid not null references auth.users(id) on delete restrict,

  identity_kind text not null,
  display_handle text not null,
  created_at timestamptz not null default now(),

  constraint identity_kind_chk check (length(btrim(identity_kind)) between 3 and 32),
  constraint identity_handle_chk check (length(btrim(display_handle)) between 6 and 64),
  constraint ux_identity_kind_handle unique (identity_kind, display_handle)
);

create table if not exists rgsr.publish_submissions (
  submission_id uuid primary key default gen_random_uuid(),
  project_id uuid not null references rgsr.projects(project_id) on delete cascade,
  owner_uid uuid not null references auth.users(id) on delete restrict,

  submitted_by uuid not null references auth.users(id) on delete restrict,
  submitted_at timestamptz not null default now(),

  phase text not null default 'draft',
  submission_kind text not null default 'systems',
  notes text not null default '',

  status text not null default 'pending',
  reviewed_by uuid null references auth.users(id) on delete set null,
  reviewed_at timestamptz null,
  rejection_reason text null,

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

  credit_role text not null,
  credit_alias text not null,
  credit_scope text not null default 'team',
  sort_order int not null default 10,

  constraint credit_role_len check (length(btrim(credit_role)) between 2 and 40),
  constraint credit_alias_len check (length(btrim(credit_alias)) between 3 and 64),
  constraint credit_scope_chk check (credit_scope in ('team','lab','institution'))
);

create index if not exists ix_publish_credits_submission on rgsr.publish_credits(submission_id, sort_order);

-- ------------------------------------------------------------
-- 2) RLS enable + force
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

-- drop existing policies on these tables (avoid union leakage)
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
-- 3) VALID policies (separate per command)
-- ------------------------------------------------------------

-- projects: public read
create policy projects_read_public on rgsr.projects
for select to anon, authenticated
using (is_public = true);

-- projects: owner read
create policy projects_read_own on rgsr.projects
for select to authenticated
using (owner_uid = rgsr.actor_uid());

-- projects: owner insert
create policy projects_insert_own on rgsr.projects
for insert to authenticated
with check (owner_uid = rgsr.actor_uid());

-- projects: owner update
create policy projects_update_own on rgsr.projects
for update to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

-- projects: owner delete
create policy projects_delete_own on rgsr.projects
for delete to authenticated
using (owner_uid = rgsr.actor_uid());

-- projects: admin all
create policy projects_admin on rgsr.projects
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- snapshots: owner read
create policy snapshots_read_own on rgsr.project_snapshots
for select to authenticated
using (owner_uid = rgsr.actor_uid());

-- snapshots: owner insert
create policy snapshots_insert_own on rgsr.project_snapshots
for insert to authenticated
with check (owner_uid = rgsr.actor_uid());

-- snapshots: owner update
create policy snapshots_update_own on rgsr.project_snapshots
for update to authenticated
using (owner_uid = rgsr.actor_uid())
with check (owner_uid = rgsr.actor_uid());

-- snapshots: owner delete
create policy snapshots_delete_own on rgsr.project_snapshots
for delete to authenticated
using (owner_uid = rgsr.actor_uid());

-- snapshots: admin all
create policy snapshots_admin on rgsr.project_snapshots
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- identities: owner read
create policy identities_read_own on rgsr.public_identities
for select to authenticated
using (owner_uid = rgsr.actor_uid());

-- identities: owner insert
create policy identities_insert_own on rgsr.public_identities
for insert to authenticated
with check (owner_uid = rgsr.actor_uid());

-- identities: owner delete (no update; keep append-only)
create policy identities_delete_own on rgsr.public_identities
for delete to authenticated
using (owner_uid = rgsr.actor_uid());

-- identities: admin all
create policy identities_admin on rgsr.public_identities
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- publish submissions: public read only approved
create policy publish_read_public on rgsr.publish_submissions
for select to anon, authenticated
using (status='approved');

-- publish submissions: owner read
create policy publish_read_own on rgsr.publish_submissions
for select to authenticated
using (owner_uid = rgsr.actor_uid());

-- publish submissions: owner insert
create policy publish_insert_own on rgsr.publish_submissions
for insert to authenticated
with check (owner_uid = rgsr.actor_uid() and submitted_by = rgsr.actor_uid());

-- publish submissions: owner update only while pending
create policy publish_update_own_pending on rgsr.publish_submissions
for update to authenticated
using (owner_uid = rgsr.actor_uid() and status='pending')
with check (owner_uid = rgsr.actor_uid() and status='pending');

-- publish submissions: owner delete only while pending
create policy publish_delete_own_pending on rgsr.publish_submissions
for delete to authenticated
using (owner_uid = rgsr.actor_uid() and status='pending');

-- publish submissions: admin all
create policy publish_admin on rgsr.publish_submissions
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- publish credits: public read only if approved submission
create policy credits_read_public on rgsr.publish_credits
for select to anon, authenticated
using (
  exists (
    select 1 from rgsr.publish_submissions ps
    where ps.submission_id = publish_credits.submission_id
      and ps.status='approved'
  )
);

-- publish credits: owner read
create policy credits_read_owner on rgsr.publish_credits
for select to authenticated
using (
  exists (
    select 1 from rgsr.publish_submissions ps
    where ps.submission_id = publish_credits.submission_id
      and ps.owner_uid = rgsr.actor_uid()
  )
);

-- publish credits: owner insert/update/delete only while pending
create policy credits_insert_owner_pending on rgsr.publish_credits
for insert to authenticated
with check (
  exists (
    select 1 from rgsr.publish_submissions ps
    where ps.submission_id = publish_credits.submission_id
      and ps.owner_uid = rgsr.actor_uid()
      and ps.status='pending'
  )
);

create policy credits_update_owner_pending on rgsr.publish_credits
for update to authenticated
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

create policy credits_delete_owner_pending on rgsr.publish_credits
for delete to authenticated
using (
  exists (
    select 1 from rgsr.publish_submissions ps
    where ps.submission_id = publish_credits.submission_id
      and ps.owner_uid = rgsr.actor_uid()
      and ps.status='pending'
  )
);

-- publish credits: admin all
create policy credits_admin on rgsr.publish_credits
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- ------------------------------------------------------------
-- 4) Storage bucket (idempotent; no policy here yet)
-- ------------------------------------------------------------
do $do$
begin
  if exists (select 1 from pg_namespace where nspname='storage') then
    insert into storage.buckets(id, name, public)
    values ('rgsr_projects','rgsr_projects', false)
    on conflict (id) do update set name=excluded.name, public=false;
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

Write-Host "✅ v12.2.2 applied (repair: valid RLS policies)" -ForegroundColor Green
