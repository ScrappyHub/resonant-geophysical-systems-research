-- ============================================================
-- RGSR v10 PRELUDE (MUST RUN BEFORE 20260102001720)
-- Ensures rgsr.labs + rgsr.lab_members columns exist so v10
-- functions (has_lab_access) compile without column errors.
-- NO LEAKAGE: this is structural only (no policies here).
-- ============================================================

begin;

create table if not exists rgsr.labs (
  lab_id uuid primary key default gen_random_uuid(),
  lane text not null default 'LAB',
  lab_code text not null unique,
  display_name text not null,
  description text null,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint labs_lane_chk check (lane in ('LAB','INTERNAL'))
);
create index if not exists ix_labs_code on rgsr.labs(lab_code);

create table if not exists rgsr.lab_members (
  membership_id uuid primary key default gen_random_uuid(),
  lab_id uuid not null references rgsr.labs(lab_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  member_role text not null default 'MEMBER',
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint lab_members_role_chk check (member_role in ('OWNER','ADMIN','MEMBER','VIEWER')),
  constraint lab_members_unique unique (lab_id, user_id)
);
create index if not exists ix_lab_members_lab on rgsr.lab_members(lab_id);
create index if not exists ix_lab_members_user on rgsr.lab_members(user_id);

-- Normalize older lab_members if it existed without these columns/constraints
do $do$
begin
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='lab_members')
     and not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='member_role') then
    execute 'alter table rgsr.lab_members add column member_role text not null default ''MEMBER''';
  end if;

  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='lab_members')
     and not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='is_active') then
    execute 'alter table rgsr.lab_members add column is_active boolean not null default true';
  end if;

  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='lab_members')
     and not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='created_at') then
    execute 'alter table rgsr.lab_members add column created_at timestamptz not null default now()';
  end if;
  if exists (select 1 from information_schema.tables where table_schema='rgsr' and table_name='lab_members')
     and not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='updated_at') then
    execute 'alter table rgsr.lab_members add column updated_at timestamptz not null default now()';
  end if;

  begin
    execute 'alter table rgsr.lab_members add constraint lab_members_unique unique (lab_id, user_id)';
  exception when duplicate_object then null;
  end;

  begin
    execute 'alter table rgsr.lab_members add constraint lab_members_role_chk check (member_role in (''OWNER'',''ADMIN'',''MEMBER'',''VIEWER''))';
  exception when duplicate_object then null;
  end;
end
$do$;

commit;
-- ============================================================
-- End prelude
-- ============================================================
