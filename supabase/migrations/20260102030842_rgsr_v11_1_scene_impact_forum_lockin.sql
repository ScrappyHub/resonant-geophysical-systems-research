-- ============================================================
-- RGSR v11.1 — SCENE CONTRACT + IMPACT STATS + COMMUNITY FORUM
-- NO PII STORED (no emails/phones/passwords in app tables)
-- UI gets canonical truth payloads (2D + 3D) (no guessing)
-- ============================================================

begin;

create schema if not exists rgsr;

-- -------------------------------
-- SCENE CONTRACT TABLES
-- -------------------------------

create table if not exists rgsr.layer_kinds (
  layer_kind      text primary key,
  domain          text not null,
  description     text null,
  default_enabled boolean not null default false,
  render_spec     jsonb not null default '{}'::jsonb,
  schema_spec     jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint layer_kinds_domain_chk check (length(domain) > 0),
  constraint layer_kinds_kind_chk   check (length(layer_kind) > 0)
);
create index if not exists ix_layer_kinds_domain on rgsr.layer_kinds(domain);

create table if not exists rgsr.run_layers (
  run_layer_id uuid primary key default gen_random_uuid(),
  run_id       uuid not null references rgsr.runs(run_id) on delete cascade,
  layer_kind   text not null references rgsr.layer_kinds(layer_kind) on delete restrict,
  is_enabled   boolean not null default true,
  overrides    jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint run_layers_unique unique (run_id, layer_kind)
);
create index if not exists ix_run_layers_run on rgsr.run_layers(run_id);
create index if not exists ix_run_layers_kind on rgsr.run_layers(layer_kind);

create table if not exists rgsr.anchors (
  anchor_id    uuid primary key default gen_random_uuid(),
  run_id       uuid not null references rgsr.runs(run_id) on delete cascade,
  anchor_kind  text not null default 'POINT',
  x            double precision null,
  y            double precision null,
  z            double precision null,
  lat          double precision null,
  lon          double precision null,
  yaw          double precision null,
  pitch        double precision null,
  roll         double precision null,
  scale        double precision null,
  label        text null,
  metadata     jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint anchors_kind_chk check (anchor_kind in ('POINT','SENSOR','STRUCTURE','REGION','POI','TRANSECT_NODE','OTHER'))
);
create index if not exists ix_anchors_run on rgsr.anchors(run_id);
create index if not exists ix_anchors_kind on rgsr.anchors(anchor_kind);

create table if not exists rgsr.geometries (
  geometry_id uuid primary key default gen_random_uuid(),
  run_id      uuid not null references rgsr.runs(run_id) on delete cascade,
  layer_kind  text null references rgsr.layer_kinds(layer_kind) on delete set null,
  geom_kind   text not null default 'GEOMETRY',
  geom_json   jsonb not null default '{}'::jsonb,
  bbox_json   jsonb not null default '{}'::jsonb,
  label       text null,
  metadata    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint geometries_kind_chk check (geom_kind in (
    'FOUNDATION','FOOTPRINT','POLYLINE','POLYGON','VOLUME','MESH','SLICE_PLANE',
    'LEYLINE','FAULTLINE','BUILDING_OUTLINE','CHAMBER','SCAN','OTHER','GEOMETRY'
  ))
);
create index if not exists ix_geometries_run on rgsr.geometries(run_id);
create index if not exists ix_geometries_layer on rgsr.geometries(layer_kind);
create index if not exists ix_geometries_kind on rgsr.geometries(geom_kind);

create table if not exists rgsr.conditions (
  condition_id uuid primary key default gen_random_uuid(),
  run_id       uuid not null references rgsr.runs(run_id) on delete cascade,
  scope        text not null,
  recorded_at  timestamptz not null default now(),
  anchor_id    uuid null references rgsr.anchors(anchor_id) on delete set null,
  payload      jsonb not null default '{}'::jsonb,
  metadata     jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint conditions_scope_chk check (scope in ('INTERNAL','EXTERNAL','WEATHER','SITE','FOUNDATION','CHAMBER','DEVICE','MEDICAL','OTHER'))
);
create index if not exists ix_conditions_run_time on rgsr.conditions(run_id, recorded_at);
create index if not exists ix_conditions_scope on rgsr.conditions(scope);
create index if not exists ix_conditions_anchor on rgsr.conditions(anchor_id);

-- explicit bindings (no UI inference)
do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='run_measurements') then
    if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='run_measurements' and column_name='binding_kind') then
      execute $$alter table rgsr.run_measurements add column binding_kind text not null default 'RUN'$$;
    end if;
    if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='run_measurements' and column_name='anchor_id') then
      execute $$alter table rgsr.run_measurements add column anchor_id uuid null references rgsr.anchors(anchor_id) on delete set null$$;
    end if;
    if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='run_measurements' and column_name='geometry_id') then
      execute $$alter table rgsr.run_measurements add column geometry_id uuid null references rgsr.geometries(geometry_id) on delete set null$$;
    end if;
    if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='run_measurements' and column_name='layer_kind') then
      execute $$alter table rgsr.run_measurements add column layer_kind text null references rgsr.layer_kinds(layer_kind) on delete set null$$;
    end if;

    begin
      execute $$alter table rgsr.run_measurements add constraint rm_binding_kind_chk
               check (binding_kind in ('RUN','ANCHOR','GEOMETRY','REGION','TRANSECT'))$$;
    exception when duplicate_object then null;
    end;

    begin
      execute $$alter table rgsr.run_measurements add constraint rm_binding_target_chk
               check (
                 (binding_kind='RUN' and anchor_id is null and geometry_id is null)
                 or (binding_kind='ANCHOR' and anchor_id is not null)
                 or (binding_kind='GEOMETRY' and geometry_id is not null)
                 or (binding_kind in ('REGION','TRANSECT'))
               )$$;
    exception when duplicate_object then null;
    end;

    create index if not exists ix_rm_anchor on rgsr.run_measurements(anchor_id);
    create index if not exists ix_rm_geometry on rgsr.run_measurements(geometry_id);
    create index if not exists ix_rm_layer_kind on rgsr.run_measurements(layer_kind);
  end if;

  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='run_artifacts') then
    if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='run_artifacts' and column_name='binding_kind') then
      execute $$alter table rgsr.run_artifacts add column binding_kind text not null default 'RUN'$$;
    end if;
    if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='run_artifacts' and column_name='anchor_id') then
      execute $$alter table rgsr.run_artifacts add column anchor_id uuid null references rgsr.anchors(anchor_id) on delete set null$$;
    end if;
    if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='run_artifacts' and column_name='geometry_id') then
      execute $$alter table rgsr.run_artifacts add column geometry_id uuid null references rgsr.geometries(geometry_id) on delete set null$$;
    end if;
    if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='run_artifacts' and column_name='layer_kind') then
      execute $$alter table rgsr.run_artifacts add column layer_kind text null references rgsr.layer_kinds(layer_kind) on delete set null$$;
    end if;

    begin
      execute $$alter table rgsr.run_artifacts add constraint ra_binding_kind_chk
               check (binding_kind in ('RUN','ANCHOR','GEOMETRY','REGION','TRANSECT'))$$;
    exception when duplicate_object then null;
    end;

    begin
      execute $$alter table rgsr.run_artifacts add constraint ra_binding_target_chk
               check (
                 (binding_kind='RUN' and anchor_id is null and geometry_id is null)
                 or (binding_kind='ANCHOR' and anchor_id is not null)
                 or (binding_kind='GEOMETRY' and geometry_id is not null)
                 or (binding_kind in ('REGION','TRANSECT'))
               )$$;
    exception when duplicate_object then null;
    end;

    create index if not exists ix_ra_anchor on rgsr.run_artifacts(anchor_id);
    create index if not exists ix_ra_geometry on rgsr.run_artifacts(geometry_id);
    create index if not exists ix_ra_layer_kind on rgsr.run_artifacts(layer_kind);
  end if;
end
$do$;

create or replace function rgsr.get_run_scene(
  p_run_id uuid,
  p_time_from timestamptz default null,
  p_time_to timestamptz default null
) returns jsonb
language plpgsql
stable
as $fn$
declare v_run jsonb;
declare v_layers jsonb;
declare v_rlayers jsonb;
declare v_anchors jsonb;
declare v_geoms jsonb;
declare v_conditions jsonb;
declare v_meas jsonb;
declare v_arts jsonb;
begin
  select to_jsonb(r.*) into v_run
  from rgsr.runs r
  where r.run_id = p_run_id;

  if v_run is null then
    return jsonb_build_object('error','RUN_NOT_FOUND_OR_NO_ACCESS');
  end if;

  select coalesce(jsonb_agg(to_jsonb(lk) order by lk.domain, lk.layer_kind), '[]'::jsonb)
    into v_layers
  from rgsr.layer_kinds lk;

  select coalesce(jsonb_agg(to_jsonb(rl) order by rl.layer_kind), '[]'::jsonb)
    into v_rlayers
  from rgsr.run_layers rl
  where rl.run_id = p_run_id;

  select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at), '[]'::jsonb)
    into v_anchors
  from rgsr.anchors a
  where a.run_id = p_run_id;

  select coalesce(jsonb_agg(to_jsonb(g) order by g.created_at), '[]'::jsonb)
    into v_geoms
  from rgsr.geometries g
  where g.run_id = p_run_id;

  select coalesce(jsonb_agg(to_jsonb(c) order by c.recorded_at), '[]'::jsonb)
    into v_conditions
  from rgsr.conditions c
  where c.run_id = p_run_id
    and (p_time_from is null or c.recorded_at >= p_time_from)
    and (p_time_to   is null or c.recorded_at <= p_time_to);

  select coalesce(jsonb_agg(to_jsonb(m) order by m.measured_at), '[]'::jsonb)
    into v_meas
  from rgsr.run_measurements m
  where m.run_id = p_run_id
    and (p_time_from is null or m.measured_at >= p_time_from)
    and (p_time_to   is null or m.measured_at <= p_time_to);

  select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at), '[]'::jsonb)
    into v_arts
  from rgsr.run_artifacts a
  where a.run_id = p_run_id
    and (p_time_from is null or a.created_at >= p_time_from)
    and (p_time_to   is null or a.created_at <= p_time_to);

  return jsonb_build_object(
    'run', v_run,
    'layer_kinds', v_layers,
    'run_layers', v_rlayers,
    'anchors', v_anchors,
    'geometries', v_geoms,
    'conditions', v_conditions,
    'measurements', v_meas,
    'artifacts', v_arts
  );
end
$fn$;

-- -------------------------------
-- IMPACT STATS (PUBLIC, NO PII)
-- -------------------------------

create table if not exists rgsr.impact_stats (
  stat_key   text primary key,
  stat_value bigint not null default 0,
  updated_at timestamptz not null default now(),
  constraint impact_stats_key_chk check (stat_key in ('experiments','researchers','data_bytes'))
);

insert into rgsr.impact_stats(stat_key, stat_value)
values ('experiments',0),('researchers',0),('data_bytes',0)
on conflict (stat_key) do nothing;

create or replace function rgsr.get_public_impact_stats()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'experiments', (select stat_value from rgsr.impact_stats where stat_key='experiments'),
    'researchers', (select stat_value from rgsr.impact_stats where stat_key='researchers'),
    'data_bytes',  (select stat_value from rgsr.impact_stats where stat_key='data_bytes'),
    'updated_at',  (select max(updated_at) from rgsr.impact_stats)
  );
$$;

-- -------------------------------
-- COMMUNITY FORUM (NO PII)
-- -------------------------------

create table if not exists rgsr.forum_posts (
  post_id     uuid primary key default gen_random_uuid(),
  created_by  uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  is_approved boolean not null default true,
  title       text not null,
  body        text not null,
  tags        text[] not null default '{}'::text[],
  metadata    jsonb not null default '{}'::jsonb,
  constraint forum_title_len_chk check (char_length(title) between 4 and 140),
  constraint forum_body_len_chk  check (char_length(body) between 10 and 5000)
);

create or replace function rgsr.is_safe_text(p text)
returns boolean
language plpgsql
immutable
as $$
begin
  if p is null then return false; end if;
  if position('<script' in lower(p)) > 0 then return false; end if;
  if position('javascript:' in lower(p)) > 0 then return false; end if;
  if position('onerror=' in lower(p)) > 0 then return false; end if;
  if position('onload=' in lower(p)) > 0 then return false; end if;
  return true;
end;
$$;

do $do$
begin
  begin
    execute $$alter table rgsr.forum_posts add constraint forum_title_safe_chk check (rgsr.is_safe_text(title))$$;
  exception when duplicate_object then null;
  end;
  begin
    execute $$alter table rgsr.forum_posts add constraint forum_body_safe_chk check (rgsr.is_safe_text(body))$$;
  exception when duplicate_object then null;
  end;
end
$do$;

-- -------------------------------
-- RLS + POLICIES (NO LEAKAGE)
-- -------------------------------

alter table rgsr.layer_kinds enable row level security;
alter table rgsr.run_layers enable row level security;
alter table rgsr.anchors enable row level security;
alter table rgsr.geometries enable row level security;
alter table rgsr.conditions enable row level security;
alter table rgsr.impact_stats enable row level security;
alter table rgsr.forum_posts enable row level security;

alter table rgsr.layer_kinds force row level security;
alter table rgsr.run_layers force row level security;
alter table rgsr.anchors force row level security;
alter table rgsr.geometries force row level security;
alter table rgsr.conditions force row level security;
alter table rgsr.impact_stats force row level security;
alter table rgsr.forum_posts force row level security;

do $do$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname='rgsr'
      and tablename in ('layer_kinds','run_layers','anchors','geometries','conditions','impact_stats','forum_posts')
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end
$do$;

create policy layer_kinds_select on rgsr.layer_kinds for select to authenticated using (true);
create policy layer_kinds_write  on rgsr.layer_kinds for all    to authenticated using (rgsr.can_write()) with check (rgsr.can_write());

create policy run_layers_select on rgsr.run_layers for select to authenticated
  using (exists (select 1 from rgsr.runs r where r.run_id=run_layers.run_id and rgsr.can_read_lane(r.lane, r.lab_id)));
create policy run_layers_write  on rgsr.run_layers for all to authenticated using (rgsr.can_write()) with check (rgsr.can_write());

create policy anchors_select on rgsr.anchors for select to authenticated
  using (exists (select 1 from rgsr.runs r where r.run_id=anchors.run_id and rgsr.can_read_lane(r.lane, r.lab_id)));
create policy anchors_write  on rgsr.anchors for all to authenticated using (rgsr.can_write()) with check (rgsr.can_write());

create policy geometries_select on rgsr.geometries for select to authenticated
  using (exists (select 1 from rgsr.runs r where r.run_id=geometries.run_id and rgsr.can_read_lane(r.lane, r.lab_id)));
create policy geometries_write  on rgsr.geometries for all to authenticated using (rgsr.can_write()) with check (rgsr.can_write());

create policy conditions_select on rgsr.conditions for select to authenticated
  using (exists (select 1 from rgsr.runs r where r.run_id=conditions.run_id and rgsr.can_read_lane(r.lane, r.lab_id)));
create policy conditions_write  on rgsr.conditions for all to authenticated using (rgsr.can_write()) with check (rgsr.can_write());

-- Impact stats: public read (anon + authenticated), write restricted
create policy impact_stats_read on rgsr.impact_stats for select to anon, authenticated using (true);
create policy impact_stats_write on rgsr.impact_stats for all to authenticated
  using (rgsr.can_write()) with check (rgsr.can_write());

-- Forum: public read approved; auth can create/update own; admins moderate via can_write()
create policy forum_posts_read on rgsr.forum_posts for select to anon, authenticated
  using (is_approved = true);

create policy forum_posts_insert on rgsr.forum_posts for insert to authenticated
  with check (created_by = auth.uid() and is_approved = true and rgsr.is_safe_text(title) and rgsr.is_safe_text(body));

create policy forum_posts_update_own on rgsr.forum_posts for update to authenticated
  using (created_by = auth.uid())
  with check (created_by = auth.uid() and rgsr.is_safe_text(title) and rgsr.is_safe_text(body));

create policy forum_posts_moderate on rgsr.forum_posts for all to authenticated
  using (rgsr.can_write())
  with check (rgsr.can_write());

-- -------------------------------
-- Grants: rgsr ONLY (do not touch auth/MFA)
-- -------------------------------
do $do$
begin
  execute 'revoke all on schema rgsr from public';
  execute 'grant usage on schema rgsr to anon';
  execute 'grant usage on schema rgsr to authenticated';
  execute 'grant usage on schema rgsr to service_role';
end
$do$;

commit;
