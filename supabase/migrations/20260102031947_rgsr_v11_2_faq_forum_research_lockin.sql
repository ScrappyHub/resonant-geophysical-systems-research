-- ============================================================
-- RGSR v11.2 — FAQ + FORUM + RESEARCH LOCK-IN (NO UI GUESSING)
-- - FAQ topics required (no free-for-all)
-- - Forum auto-approve only if sanitized + passes profanity filter
-- - Research uploads use same moderation path (low risk but still gated)
-- - Admin delete/moderation via rgsr.can_write() ONLY
-- - Filterability: tags + full-text search indexes
-- - DOES NOT TOUCH auth schema / MFA tables
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 0) Guard: schema must exist
-- ------------------------------------------------------------
do $do$
begin
  if to_regnamespace('rgsr') is null then
    return;
  end if;
end
$do$;

-- ------------------------------------------------------------
-- 1) Profanity term registry (admin-managed)
-- ------------------------------------------------------------
create table if not exists rgsr.profanity_terms (
  term text primary key,
  created_at timestamptz not null default now()
);

-- Basic seed (lightweight). You can expand this later safely.
insert into rgsr.profanity_terms(term)
values ('<REPLACE_WITH_YOUR_LIST_LATER>')
on conflict do nothing;

-- ------------------------------------------------------------
-- 2) FAQ / Topic contract (required for forum)
-- ------------------------------------------------------------
create table if not exists rgsr.forum_topics (
  topic_id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  prompt text not null,
  is_active boolean not null default true,
  sort_order int not null default 100,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint forum_topics_slug_chk check (length(slug) > 1)
);

-- Canonical seeded topics (acts as your FAQ-driven rails)
insert into rgsr.forum_topics (slug, title, prompt, sort_order)
values
  ('general', 'General Questions', 'Ask questions about the platform and how to run experiments safely.', 10),
  ('how-to', 'How-to / Workflow', 'Questions about setting up runs, layers, measurements, artifacts, and viewing results.', 20),
  ('interpretation', 'Interpreting Results', 'Discuss interpretation, methods, and how to read outputs (no medical advice).', 30),
  ('datasets', 'Data & Uploads', 'Talk about datasets, file formats, metadata, and research uploads.', 40),
  ('hardware', 'Sensors & Hardware', 'Discuss devices, calibration, hydro-acoustics/acoustics, and instrument setup.', 50),
  ('architecture', 'Architecture & Geology', 'Site/foundation, geometry, conditions, leylines/faultlines as declared layers.', 60)
on conflict (slug) do nothing;

create index if not exists ix_forum_topics_active on rgsr.forum_topics(is_active);

-- ------------------------------------------------------------
-- 3) Sanitization + moderation helpers (portable, deterministic)
-- ------------------------------------------------------------
create or replace function rgsr.sanitize_text(p text)
returns text
language sql
immutable
as $fn$
  select
    -- remove control chars, normalize whitespace, strip angle brackets
    trim(
      regexp_replace(
        regexp_replace(
          regexp_replace(coalesce(p,''), '[[:cntrl:]]', '', 'g'),
          '\s+', ' ', 'g'
        ),
        '[<>]', '', 'g'
      )
    )
$fn$;

create or replace function rgsr.contains_profanity(p text)
returns boolean
language plpgsql
stable
as $fn$
declare v boolean;
begin
  -- if no term list, treat as clean
  if not exists (select 1 from rgsr.profanity_terms where term is not null and length(term) > 0 and term not like '<%') then
    return false;
  end if;

  select exists(
    select 1
    from rgsr.profanity_terms t
    where length(t.term) > 0
      and lower(rgsr.sanitize_text(p)) like ('%' || lower(t.term) || '%')
  ) into v;

  return v;
end
$fn$;

-- returns (approved, reason, clean_title, clean_body)
create or replace function rgsr.moderate_post(p_title text, p_body text)
returns table(is_ok boolean, reason text, clean_title text, clean_body text)
language plpgsql
stable
as $fn$
declare
  t text;
  b text;
begin
  t := rgsr.sanitize_text(p_title);
  b := rgsr.sanitize_text(p_body);

  if length(t) < 3 then
    return query select false, 'TITLE_TOO_SHORT', t, b; return;
  end if;
  if length(t) > 140 then
    return query select false, 'TITLE_TOO_LONG', t, b; return;
  end if;
  if length(b) < 10 then
    return query select false, 'BODY_TOO_SHORT', t, b; return;
  end if;
  if length(b) > 12000 then
    return query select false, 'BODY_TOO_LONG', t, b; return;
  end if;

  if rgsr.contains_profanity(t) or rgsr.contains_profanity(b) then
    return query select false, 'PROFANITY', t, b; return;
  end if;

  -- link spam heuristic (very simple, deterministic)
  if (length(regexp_replace(b, 'https?://', '', 'g')) <= length(b) - 40) then
    -- has lots of http occurrences / heavy links
    return query select false, 'LINK_HEAVY', t, b; return;
  end if;

  return query select true, null, t, b;
end
$fn$;

-- ------------------------------------------------------------
-- 4) Forum posts: enforce FAQ topic + canonical columns
-- ------------------------------------------------------------
do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='forum_posts') then

    if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='forum_posts' and column_name='topic_id') then
      execute 'alter table rgsr.forum_posts add column topic_id uuid null references rgsr.forum_topics(topic_id) on delete restrict';
    end if;

    if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='forum_posts' and column_name='approved_at') then
      execute 'alter table rgsr.forum_posts add column approved_at timestamptz null';
    end if;

    if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='forum_posts' and column_name='rejected_reason') then
      execute 'alter table rgsr.forum_posts add column rejected_reason text null';
    end if;

    -- Backfill: assign any existing posts to "general" topic if missing
    execute $q$
      update rgsr.forum_posts p
      set topic_id = (select topic_id from rgsr.forum_topics where slug='general' limit 1)
      where p.topic_id is null
    $q$;

    -- Enforce NOT NULL on topic_id safely (idempotent)
    begin
      execute 'alter table rgsr.forum_posts alter column topic_id set not null';
    exception when others then
      -- if the column doesn't exist or already set, ignore
      null;
    end;

    -- Ensure body/title are sanitized-at-rest: normalize existing rows once
    execute $q$
      update rgsr.forum_posts
      set title = rgsr.sanitize_text(title),
          body  = rgsr.sanitize_text(body)
      where title <> rgsr.sanitize_text(title) or body <> rgsr.sanitize_text(body)
    $q$;

  end if;
end
$do$;

-- ------------------------------------------------------------
-- 5) Research uploads (auto-approve only if passes same moderation)
-- ------------------------------------------------------------
create table if not exists rgsr.research_uploads (
  research_id uuid primary key default gen_random_uuid(),
  created_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  is_approved boolean not null default false,
  approved_at timestamptz null,
  title text not null,
  body text not null,
  tags text[] not null default '{}'::text[],
  source_kind text not null default 'USER',
  metadata jsonb not null default '{}'::jsonb,
  constraint research_source_kind_chk check (source_kind in ('USER','ENGINE','IMPORT','OTHER'))
);

create index if not exists ix_research_uploads_created_at on rgsr.research_uploads(created_at desc);
create index if not exists ix_research_uploads_tags on rgsr.research_uploads using gin(tags);
create index if not exists ix_research_uploads_fts on rgsr.research_uploads using gin(
  to_tsvector('english', coalesce(title,'') || ' ' || coalesce(body,''))
);

-- ------------------------------------------------------------
-- 6) Canonical RPCs: ONLY safe path for “auto-approve”
-- ------------------------------------------------------------
-- Forum submit: enforces topic slug, sanitizes, auto-approves if passes checks.
create or replace function rgsr.submit_forum_post(
  p_topic_slug text,
  p_title text,
  p_body text,
  p_tags text[] default '{}'::text[]
) returns jsonb
language plpgsql
security definer
as $fn$
declare
  v_topic_id uuid;
  v_ok boolean;
  v_reason text;
  v_ct text;
  v_cb text;
  v_id uuid;
begin
  -- resolve topic
  select topic_id into v_topic_id
  from rgsr.forum_topics
  where slug = rgsr.sanitize_text(p_topic_slug) and is_active = true
  limit 1;

  if v_topic_id is null then
    return jsonb_build_object('error','INVALID_TOPIC');
  end if;

  select is_ok, reason, clean_title, clean_body
    into v_ok, v_reason, v_ct, v_cb
  from rgsr.moderate_post(p_title, p_body);

  insert into rgsr.forum_posts (
    post_id, created_by, created_at, updated_at,
    is_approved, approved_at,
    topic_id, title, body, tags, metadata, rejected_reason
  ) values (
    gen_random_uuid(), rgsr.me(), now(), now(),
    v_ok, case when v_ok then now() else null end,
    v_topic_id, v_ct, v_cb, coalesce(p_tags,'{}'::text[]),
    jsonb_build_object('auto_moderated', true),
    v_reason
  )
  returning post_id into v_id;

  return jsonb_build_object('post_id', v_id, 'is_approved', v_ok, 'reason', v_reason);
end
$fn$;

-- Research submit: same moderation; approved if passes checks.
create or replace function rgsr.submit_research_upload(
  p_title text,
  p_body text,
  p_tags text[] default '{}'::text[]
) returns jsonb
language plpgsql
security definer
as $fn$
declare
  v_ok boolean;
  v_reason text;
  v_ct text;
  v_cb text;
  v_id uuid;
begin
  select is_ok, reason, clean_title, clean_body
    into v_ok, v_reason, v_ct, v_cb
  from rgsr.moderate_post(p_title, p_body);

  insert into rgsr.research_uploads (
    research_id, created_by, created_at, updated_at,
    is_approved, approved_at,
    title, body, tags, source_kind, metadata
  ) values (
    gen_random_uuid(), rgsr.me(), now(), now(),
    v_ok, case when v_ok then now() else null end,
    v_ct, v_cb, coalesce(p_tags,'{}'::text[]), 'USER',
    jsonb_build_object('auto_moderated', true, 'reason', v_reason)
  )
  returning research_id into v_id;

  return jsonb_build_object('research_id', v_id, 'is_approved', v_ok, 'reason', v_reason);
end
$fn$;

-- ------------------------------------------------------------
-- 7) Policies: drop+recreate (forum_posts, impact_stats, research_uploads)
-- ------------------------------------------------------------

-- research_uploads RLS
alter table rgsr.research_uploads enable row level security;
alter table rgsr.research_uploads force row level security;

-- Drop any existing policies on these tables
do $do$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname='rgsr'
      and tablename in ('forum_posts','impact_stats','research_uploads','forum_topics','profanity_terms')
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end
$do$;

-- forum_topics: public read (so FAQ page can render), write only admins
alter table rgsr.forum_topics enable row level security;
alter table rgsr.forum_topics force row level security;

create policy forum_topics_read on rgsr.forum_topics
for select to anon, authenticated
using (is_active = true);

create policy forum_topics_write on rgsr.forum_topics
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- profanity_terms: not public; admin only
alter table rgsr.profanity_terms enable row level security;
alter table rgsr.profanity_terms force row level security;

create policy profanity_terms_admin on rgsr.profanity_terms
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- forum_posts:
-- Read: public sees only approved
create policy forum_posts_read on rgsr.forum_posts
for select to anon, authenticated
using (is_approved = true);

-- Insert: authenticated allowed only if (a) self-owned, (b) sanitized-at-rest, (c) passes profanity, (d) topic exists
create policy forum_posts_insert on rgsr.forum_posts
for insert to authenticated
with check (
  created_by = rgsr.me()
  and topic_id is not null
  and exists (select 1 from rgsr.forum_topics t where t.topic_id = forum_posts.topic_id and t.is_active = true)
  and title = rgsr.sanitize_text(title)
  and body  = rgsr.sanitize_text(body)
  and rgsr.contains_profanity(title) = false
  and rgsr.contains_profanity(body)  = false
);

-- Update own: allow user to edit only THEIR unapproved post, still sanitized + clean
create policy forum_posts_update_own on rgsr.forum_posts
for update to authenticated
using (created_by = rgsr.me() and is_approved = false)
with check (
  created_by = rgsr.me()
  and is_approved = false
  and title = rgsr.sanitize_text(title)
  and body  = rgsr.sanitize_text(body)
  and rgsr.contains_profanity(title) = false
  and rgsr.contains_profanity(body)  = false
);

-- Moderate/admin: full control INCLUDING DELETE
create policy forum_posts_moderate on rgsr.forum_posts
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- impact_stats: public read, admin write
create policy impact_stats_read on rgsr.impact_stats
for select to anon, authenticated
using (true);

create policy impact_stats_write on rgsr.impact_stats
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- research_uploads:
create policy research_read on rgsr.research_uploads
for select to anon, authenticated
using (is_approved = true);

create policy research_insert on rgsr.research_uploads
for insert to authenticated
with check (
  created_by = rgsr.me()
  and title = rgsr.sanitize_text(title)
  and body  = rgsr.sanitize_text(body)
  and rgsr.contains_profanity(title) = false
  and rgsr.contains_profanity(body)  = false
);

create policy research_update_own on rgsr.research_uploads
for update to authenticated
using (created_by = rgsr.me() and is_approved = false)
with check (
  created_by = rgsr.me()
  and is_approved = false
  and title = rgsr.sanitize_text(title)
  and body  = rgsr.sanitize_text(body)
  and rgsr.contains_profanity(title) = false
  and rgsr.contains_profanity(body)  = false
);

create policy research_moderate on rgsr.research_uploads
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- ------------------------------------------------------------
-- 8) Filterability indexes on forum_posts (tags + FTS)
-- ------------------------------------------------------------
create index if not exists ix_forum_posts_tags on rgsr.forum_posts using gin(tags);
create index if not exists ix_forum_posts_fts on rgsr.forum_posts using gin(
  to_tsvector('english', coalesce(title,'') || ' ' || coalesce(body,''))
);
create index if not exists ix_forum_posts_topic on rgsr.forum_posts(topic_id);
create index if not exists ix_forum_posts_approved on rgsr.forum_posts(is_approved);

commit;

-- ============================================================
-- Manual smoke tests (run in SQL editor):
-- 1) FAQ topics visible to anon:
--    select slug,title from rgsr.forum_topics where is_active=true order by sort_order;
-- 2) Forum submit:
--    select rgsr.submit_forum_post('how-to','Title here','Body here', array['runs','layers']);
-- 3) Research submit:
--    select rgsr.submit_research_upload('Dataset format','Details...', array['hydro','acoustics']);
-- 4) Policies:
--    select tablename, policyname, cmd, roles from pg_policies
--      where schemaname='rgsr' and tablename in ('forum_posts','forum_topics','research_uploads','impact_stats')
--      order by tablename, policyname, cmd;
-- ============================================================