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

if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "RepoRoot not found: $RepoRoot" }
Set-Location $RepoRoot

$mgDir = Join-Path $RepoRoot "supabase\migrations"
EnsureDir $mgDir

Write-Host ("[INFO] RepoRoot=" + $RepoRoot) -ForegroundColor Gray
Write-Host ("[INFO] mgDir=" + $mgDir) -ForegroundColor Gray

$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_forum_contact_research_and_domains_v1.sql" -f $MigrationId)

$sql = @"
-- ============================================================
-- RGSR: Forum + Contact + Research (governed) + Domain fields
-- Canonical / idempotent / RLS-first / reproducible
-- ============================================================

begin;

-- ---------------------------
-- 0) Minimal guardrails helpers (do not assume)
-- ---------------------------

create or replace function rgsr.is_sys_admin()
returns boolean
language sql stable as \$sql\$
  select coalesce(
    (select (auth.jwt() -> 'app_metadata' ->> 'role') = 'sys_admin'),
    false
  );
\$sql\$;

create or replace function rgsr.is_service_role()
returns boolean
language sql stable as \$sql\$
  select coalesce(
    (select (auth.jwt() ->> 'role') = 'service_role'),
    false
  );
\$sql\$;

-- ---------------------------
-- 1) User preferences: research opt-in visibility (non-breaking)
-- ---------------------------
do \$do\$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema='rgsr' and table_name='user_preferences'
  ) then
    execute 'alter table rgsr.user_preferences add column if not exists research_opt_in boolean not null default false';
    execute 'alter table rgsr.user_preferences add column if not exists research_display_name_opt_in boolean not null default false';
  end if;
end
\$do\$;

-- ---------------------------
-- 2) Domain state expansion (missing canonical condition fields)
--    Adds columns to rgsr.condition_profiles if table exists.
--    (Does not infer values; only stores measured state.)
-- ---------------------------
do \$do\$
begin
  if exists (
    select 1 from information_schema.tables
    where table_schema='rgsr' and table_name='condition_profiles'
  ) then
    -- Water domain
    execute 'alter table rgsr.condition_profiles add column if not exists incoming_water_temp_c numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists water_temp_c numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists water_depth_cm numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists salinity_ppt numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists flow_rate_lpm numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists turbulence_index numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists stratification_index numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists water_container_material text';

    -- Thermal
    execute 'alter table rgsr.condition_profiles add column if not exists chamber_temp_c numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists ambient_air_temp_c numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists thermal_gradient_c_per_m numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists thermal_drift_c_per_hr numeric';

    -- Atmospheric & weather
    execute 'alter table rgsr.condition_profiles add column if not exists season text';
    execute 'alter table rgsr.condition_profiles add column if not exists weather_pattern text';
    execute 'alter table rgsr.condition_profiles add column if not exists wind_mps numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists barometric_pressure_hpa numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists humidity_pct numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists air_density_kg_m3 numeric';

    -- Airflow & ventilation
    execute 'alter table rgsr.condition_profiles add column if not exists vent_count integer';
    execute 'alter table rgsr.condition_profiles add column if not exists vent_open_pct numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists airflow_rate_m3_s numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists airflow_direction_deg numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists airflow_turbulence_index numeric';

    -- Materials & geology
    execute 'alter table rgsr.condition_profiles add column if not exists chamber_material text';
    execute 'alter table rgsr.condition_profiles add column if not exists casing_material text';
    execute 'alter table rgsr.condition_profiles add column if not exists substrate_material text';
    execute 'alter table rgsr.condition_profiles add column if not exists density_kg_m3 numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists elastic_modulus_gpa numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists porosity_pct numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists crystalline_structure text';

    -- Electromagnetic
    execute 'alter table rgsr.condition_profiles add column if not exists em_background_uT numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists em_induced_uT numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists em_field_orientation_deg numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists shielding_description text';
    execute 'alter table rgsr.condition_profiles add column if not exists conductivity_s_m numeric';

    -- Geometry & coupling
    execute 'alter table rgsr.condition_profiles add column if not exists grid_size integer';
    execute 'alter table rgsr.condition_profiles add column if not exists node_spacing_cm numeric';
    execute 'alter table rgsr.condition_profiles add column if not exists boundary_conditions text';
    execute 'alter table rgsr.condition_profiles add column if not exists water_channels_description text';
    execute 'alter table rgsr.condition_profiles add column if not exists subsurface_volumes_description text';
    execute 'alter table rgsr.condition_profiles add column if not exists vent_shafts_description text';
  end if;
end
\$do\$;

-- ---------------------------
-- 3) Community Forum (lane + lab aware)
-- ---------------------------
create table if not exists rgsr.forum_categories (
  category_id uuid primary key default gen_random_uuid(),
  lane text not null default 'PUBLIC', -- PUBLIC | LAB | INTERNAL
  lab_id uuid null,
  name text not null,
  description text,
  is_locked boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists rgsr.forum_threads (
  thread_id uuid primary key default gen_random_uuid(),
  category_id uuid not null references rgsr.forum_categories(category_id) on delete cascade,
  lane text not null default 'PUBLIC',
  lab_id uuid null,
  title text not null,
  created_by uuid references auth.users(id) on delete set null,
  is_pinned boolean not null default false,
  is_locked boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists rgsr.forum_posts (
  post_id uuid primary key default gen_random_uuid(),
  thread_id uuid not null references rgsr.forum_threads(thread_id) on delete cascade,
  lane text not null default 'PUBLIC',
  lab_id uuid null,
  body text not null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists ix_forum_threads_category_time on rgsr.forum_threads(category_id, updated_at desc);
create index if not exists ix_forum_posts_thread_time on rgsr.forum_posts(thread_id, created_at asc);

alter table rgsr.forum_categories enable row level security;
alter table rgsr.forum_threads enable row level security;
alter table rgsr.forum_posts enable row level security;

-- Forum RLS: read for authenticated; moderation via sys_admin/service_role
drop policy if exists forum_cat_select on rgsr.forum_categories;
create policy forum_cat_select on rgsr.forum_categories for select to authenticated
using (true);

drop policy if exists forum_cat_write on rgsr.forum_categories;
create policy forum_cat_write on rgsr.forum_categories for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists forum_cat_update on rgsr.forum_categories;
create policy forum_cat_update on rgsr.forum_categories for update to authenticated
using (rgsr.is_sys_admin() or rgsr.is_service_role())
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists forum_thr_select on rgsr.forum_threads;
create policy forum_thr_select on rgsr.forum_threads for select to authenticated
using (true);

drop policy if exists forum_thr_insert on rgsr.forum_threads;
create policy forum_thr_insert on rgsr.forum_threads for insert to authenticated
with check (auth.uid() is not null);

drop policy if exists forum_thr_update on rgsr.forum_threads;
create policy forum_thr_update on rgsr.forum_threads for update to authenticated
using (
  (created_by = auth.uid() and is_locked = false)
  or rgsr.is_sys_admin()
  or rgsr.is_service_role()
)
with check (
  (created_by = auth.uid() and is_locked = false)
  or rgsr.is_sys_admin()
  or rgsr.is_service_role()
);

drop policy if exists forum_post_select on rgsr.forum_posts;
create policy forum_post_select on rgsr.forum_posts for select to authenticated
using (true);

drop policy if exists forum_post_insert on rgsr.forum_posts;
create policy forum_post_insert on rgsr.forum_posts for insert to authenticated
with check (auth.uid() is not null);

drop policy if exists forum_post_update on rgsr.forum_posts;
create policy forum_post_update on rgsr.forum_posts for update to authenticated
using (
  (created_by = auth.uid())
  or rgsr.is_sys_admin()
  or rgsr.is_service_role()
)
with check (
  (created_by = auth.uid())
  or rgsr.is_sys_admin()
  or rgsr.is_service_role()
);

-- ---------------------------
-- 4) Contact messages (governed intake)
-- ---------------------------
create table if not exists rgsr.contact_messages (
  message_id uuid primary key default gen_random_uuid(),
  from_user_id uuid references auth.users(id) on delete set null,
  email text,
  subject text not null,
  body text not null,
  metadata jsonb not null default '{}'::jsonb,
  status text not null default 'NEW', -- NEW | TRIAGED | CLOSED
  created_at timestamptz not null default now()
);

alter table rgsr.contact_messages enable row level security;

drop policy if exists contact_insert on rgsr.contact_messages;
create policy contact_insert on rgsr.contact_messages for insert to authenticated
with check (auth.uid() is not null);

drop policy if exists contact_select_admin on rgsr.contact_messages;
create policy contact_select_admin on rgsr.contact_messages for select to authenticated
using (rgsr.is_sys_admin() or rgsr.is_service_role());

-- ---------------------------
-- 5) Research governance
--    - submissions: PENDING by default
--    - admin approval required unless "vetted submitter" (>= 5 approved)
--    - published research visible only if:
--        (a) approved/published AND
--        (b) author opted-in AND
--        (c) viewer opted-in
-- ---------------------------

create table if not exists rgsr.research_submitter_stats (
  user_id uuid primary key references auth.users(id) on delete cascade,
  approved_count integer not null default 0,
  rejected_count integer not null default 0,
  is_banned boolean not null default false,
  updated_at timestamptz not null default now()
);

create table if not exists rgsr.research_submissions (
  submission_id uuid primary key default gen_random_uuid(),
  lane text not null default 'PUBLIC', -- PUBLIC | LAB | INTERNAL
  lab_id uuid null,
  created_by uuid not null references auth.users(id) on delete cascade,
  title text not null,
  abstract text not null,
  methods text,
  results_summary text,
  attachments jsonb not null default '[]'::jsonb, -- [{name,url,sha256,content_type}]
  metadata jsonb not null default '{}'::jsonb,
  status text not null default 'PENDING', -- PENDING | APPROVED | REJECTED | PUBLISHED
  decision_note text,
  decided_by uuid references auth.users(id) on delete set null,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists rgsr.research_publications (
  publication_id uuid primary key default gen_random_uuid(),
  submission_id uuid unique not null references rgsr.research_submissions(submission_id) on delete cascade,
  lane text not null default 'PUBLIC',
  lab_id uuid null,
  author_user_id uuid not null references auth.users(id) on delete cascade,
  author_opt_in boolean not null default false, -- author must opt-in to show
  is_admin_approved boolean not null default false,
  published_at timestamptz not null default now(),
  title text not null,
  abstract text not null,
  results_summary text,
  attachments jsonb not null default '[]'::jsonb,
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists ix_research_submissions_status_time on rgsr.research_submissions(status, updated_at desc);
create index if not exists ix_research_publications_time on rgsr.research_publications(published_at desc);

alter table rgsr.research_submitter_stats enable row level security;
alter table rgsr.research_submissions enable row level security;
alter table rgsr.research_publications enable row level security;

-- Stats: user can read own; admin can read all; admin/service writes
drop policy if exists rs_stats_select on rgsr.research_submitter_stats;
create policy rs_stats_select on rgsr.research_submitter_stats for select to authenticated
using (user_id = auth.uid() or rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists rs_stats_write on rgsr.research_submitter_stats;
create policy rs_stats_write on rgsr.research_submitter_stats for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists rs_stats_update on rgsr.research_submitter_stats;
create policy rs_stats_update on rgsr.research_submitter_stats for update to authenticated
using (rgsr.is_sys_admin() or rgsr.is_service_role())
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

-- Submissions: user can read own; admin can read all; insert by authenticated; updates limited
drop policy if exists rs_sub_select on rgsr.research_submissions;
create policy rs_sub_select on rgsr.research_submissions for select to authenticated
using (created_by = auth.uid() or rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists rs_sub_insert on rgsr.research_submissions;
create policy rs_sub_insert on rgsr.research_submissions for insert to authenticated
with check (created_by = auth.uid());

drop policy if exists rs_sub_update on rgsr.research_submissions;
create policy rs_sub_update on rgsr.research_submissions for update to authenticated
using (
  (created_by = auth.uid() and status = 'PENDING')
  or rgsr.is_sys_admin()
  or rgsr.is_service_role()
)
with check (
  (created_by = auth.uid() and status = 'PENDING')
  or rgsr.is_sys_admin()
  or rgsr.is_service_role()
);

-- Publications: select governed by opt-ins; writes admin/service only
drop policy if exists rs_pub_select on rgsr.research_publications;
create policy rs_pub_select on rgsr.research_publications for select to authenticated
using (
  -- author must opt-in
  author_opt_in = true
  -- viewer must opt-in (if prefs exist); if prefs table missing, default = false (safety)
  and coalesce(
    (select p.research_opt_in from rgsr.user_preferences p where p.user_id = auth.uid()),
    false
  ) = true
);

drop policy if exists rs_pub_write on rgsr.research_publications;
create policy rs_pub_write on rgsr.research_publications for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists rs_pub_update on rgsr.research_publications;
create policy rs_pub_update on rgsr.research_publications for update to authenticated
using (rgsr.is_sys_admin() or rgsr.is_service_role())
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

-- ---------------------------
-- 5a) Vetted submitter rule + publish workflow RPCs
-- ---------------------------

create or replace function rgsr.is_vetted_research_submitter(p_user uuid)
returns boolean
language sql stable as \$sql\$
  select
    coalesce((select s.is_banned from rgsr.research_submitter_stats s where s.user_id = p_user), false) = false
    and coalesce((select s.approved_count from rgsr.research_submitter_stats s where s.user_id = p_user), 0) >= 5;
\$sql\$;

create or replace function rgsr.submit_research(
  p_lane text,
  p_lab uuid,
  p_title text,
  p_abstract text,
  p_methods text,
  p_results_summary text,
  p_attachments jsonb,
  p_author_opt_in boolean
)
returns uuid
language plpgsql
security definer
set search_path = rgsr, public, auth as \$plpgsql\$
declare
  v_user uuid := auth.uid();
  v_submission uuid;
  v_auto boolean;
begin
  if v_user is null then
    raise exception 'auth required';
  end if;

  insert into rgsr.research_submitter_stats(user_id)
  values (v_user)
  on conflict (user_id) do nothing;

  v_auto := rgsr.is_vetted_research_submitter(v_user);

  insert into rgsr.research_submissions(
    lane, lab_id, created_by, title, abstract, methods, results_summary, attachments, status
  ) values (
    coalesce(p_lane,'PUBLIC'),
    p_lab,
    v_user,
    p_title,
    p_abstract,
    p_methods,
    p_results_summary,
    coalesce(p_attachments,'[]'::jsonb),
    case when v_auto then 'PUBLISHED' else 'PENDING' end
  )
  returning submission_id into v_submission;

  if v_auto then
    insert into rgsr.research_publications(
      submission_id, lane, lab_id, author_user_id, author_opt_in, is_admin_approved,
      title, abstract, results_summary, attachments, metadata
    ) values (
      v_submission,
      coalesce(p_lane,'PUBLIC'),
      p_lab,
      v_user,
      coalesce(p_author_opt_in,false),
      true,
      p_title,
      p_abstract,
      p_results_summary,
      coalesce(p_attachments,'[]'::jsonb),
      jsonb_build_object('auto_published', true)
    );

    update rgsr.research_submitter_stats
      set approved_count = approved_count + 1,
          updated_at = now()
    where user_id = v_user;
  end if;

  return v_submission;
end;
\$plpgsql\$;

revoke all on function rgsr.submit_research(text, uuid, text, text, text, text, jsonb, boolean) from public;
grant execute on function rgsr.submit_research(text, uuid, text, text, text, text, jsonb, boolean) to authenticated;

create or replace function rgsr.admin_approve_research(
  p_submission uuid,
  p_publish boolean,
  p_decision_note text default null,
  p_force_author_opt_in boolean default null
)
returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as \$plpgsql\$
declare
  v_sub rgsr.research_submissions%rowtype;
begin
  if not (rgsr.is_sys_admin() or rgsr.is_service_role()) then
    raise exception 'admin/service required';
  end if;

  select * into v_sub from rgsr.research_submissions where submission_id = p_submission for update;
  if not found then raise exception 'submission not found'; end if;

  update rgsr.research_submissions
    set status = case when p_publish then 'PUBLISHED' else 'APPROVED' end,
        decided_by = auth.uid(),
        decided_at = now(),
        decision_note = p_decision_note,
        updated_at = now()
  where submission_id = p_submission;

  if p_publish then
    insert into rgsr.research_publications(
      submission_id, lane, lab_id, author_user_id, author_opt_in, is_admin_approved,
      title, abstract, results_summary, attachments, metadata
    )
    values (
      v_sub.submission_id, v_sub.lane, v_sub.lab_id, v_sub.created_by,
      coalesce(p_force_author_opt_in, false),
      true,
      v_sub.title, v_sub.abstract, v_sub.results_summary, v_sub.attachments,
      jsonb_build_object('admin_approved', true)
    )
    on conflict (submission_id) do update
      set is_admin_approved = true,
          author_opt_in = coalesce(p_force_author_opt_in, rgsr.research_publications.author_opt_in),
          title = excluded.title,
          abstract = excluded.abstract,
          results_summary = excluded.results_summary,
          attachments = excluded.attachments,
          metadata = excluded.metadata;

    update rgsr.research_submitter_stats
      set approved_count = approved_count + 1,
          updated_at = now()
    where user_id = v_sub.created_by;
  end if;
end;
\$plpgsql\$;

revoke all on function rgsr.admin_approve_research(uuid, boolean, text, boolean) from public;
grant execute on function rgsr.admin_approve_research(uuid, boolean, text, boolean) to authenticated;

-- Published research feed (already RLS-filtered, returns JSON)
create or replace function rgsr.get_published_research_feed(p_limit int default 50)
returns jsonb
language sql
stable as \$sql\$
  select jsonb_build_object(
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
        'publication_id', p.publication_id,
        'submission_id', p.submission_id,
        'lane', p.lane,
        'lab_id', p.lab_id,
        'author_user_id', p.author_user_id,
        'published_at', p.published_at,
        'title', p.title,
        'abstract', p.abstract,
        'results_summary', p.results_summary,
        'attachments', p.attachments,
        'metadata', p.metadata
      ) order by p.published_at desc)
      from (
        select * from rgsr.research_publications
        order by published_at desc
        limit greatest(1, least(p_limit, 200))
      ) p
    ), '[]'::jsonb)
  );
\$sql\$;

grant execute on function rgsr.get_published_research_feed(int) to authenticated;

commit;

-- ============================================================
-- End migration
-- ============================================================
"@

WriteUtf8NoBom $mgPath ($sql + "`r`n")
Write-Host ("[OK] NEW MIGRATION READY: " + $mgPath) -ForegroundColor Green

if ($LinkProject) {
  if (-not $ProjectRef) { throw "ProjectRef is required for link." }
  & supabase link --project-ref $ProjectRef
  Write-Host "[OK] supabase link complete" -ForegroundColor Green
}

if ($ApplyRemote) {
  cmd /c "echo y| supabase db push"
  Write-Host "[OK] supabase db push complete" -ForegroundColor Green
}

Write-Host "✅ ONE-SHOT PIPELINE COMPLETE (v5)" -ForegroundColor Green