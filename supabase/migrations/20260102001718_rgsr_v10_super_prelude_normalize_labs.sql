-- ============================================================
-- RGSR v10 SUPER PRELUDE (MUST RUN BEFORE 20260102001719 + 01720)
-- Purpose: normalize existing rgsr.labs + rgsr.lab_members so later
-- preludes/migrations that reference lab_code/is_active cannot fail.
-- NOTE: Uses partial unique index on lab_code to avoid breaking on
-- legacy rows that may not have lab_code populated yet.
-- ============================================================

begin;

-- Ensure labs exists (minimal). If it already exists, no-op.
create table if not exists rgsr.labs (
  lab_id uuid primary key default gen_random_uuid()
);

-- Normalize labs columns BEFORE any index references
do $do$
begin
  if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='labs' and column_name='lane') then
    execute 'alter table rgsr.labs add column lane text not null default ''LAB''';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='labs' and column_name='lab_code') then
    -- add nullable first (legacy rows may exist); v11 will enforce invariants
    execute 'alter table rgsr.labs add column lab_code text null';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='labs' and column_name='display_name') then
    execute 'alter table rgsr.labs add column display_name text null';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='labs' and column_name='description') then
    execute 'alter table rgsr.labs add column description text null';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='labs' and column_name='created_by') then
    execute 'alter table rgsr.labs add column created_by uuid null';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='labs' and column_name='created_at') then
    execute 'alter table rgsr.labs add column created_at timestamptz not null default now()';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='labs' and column_name='updated_at') then
    execute 'alter table rgsr.labs add column updated_at timestamptz not null default now()';
  end if;

  -- Best-effort constraint adds (won't fail if already present)
  begin
    execute 'alter table rgsr.labs add constraint labs_lane_chk check (lane in (''LAB'',''INTERNAL''))';
  exception when duplicate_object then null;
  end;

  -- Best-effort FK for created_by if auth.users exists
  if exists (select 1 from information_schema.tables where table_schema='auth' and table_name='users') then
    begin
      execute 'alter table rgsr.labs add constraint labs_created_by_fk foreign key (created_by) references auth.users(id) on delete set null';
    exception when duplicate_object then null;
    end;
  end if;
end
$do$;

-- Indexes AFTER columns exist
-- partial unique to avoid legacy null explosions
create unique index if not exists ux_labs_lab_code_notnull on rgsr.labs(lab_code) where lab_code is not null;
create index if not exists ix_labs_code on rgsr.labs(lab_code);

-- Ensure lab_members exists (minimal) then normalize expected columns
create table if not exists rgsr.lab_members (
  membership_id uuid primary key default gen_random_uuid(),
  lab_id uuid null,
  user_id uuid null
);

do $do$
begin
  if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='member_role') then
    execute 'alter table rgsr.lab_members add column member_role text not null default ''MEMBER''';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='is_active') then
    execute 'alter table rgsr.lab_members add column is_active boolean not null default true';
  end if;

  if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='created_at') then
    execute 'alter table rgsr.lab_members add column created_at timestamptz not null default now()';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='updated_at') then
    execute 'alter table rgsr.lab_members add column updated_at timestamptz not null default now()';
  end if;

  -- Role constraint best-effort
  begin
    execute 'alter table rgsr.lab_members add constraint lab_members_role_chk check (member_role in (''OWNER'',''ADMIN'',''MEMBER'',''VIEWER''))';
  exception when duplicate_object then null;
  end;

  -- Unique best-effort (only if both columns exist)
  if exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='lab_id')
     and exists (select 1 from information_schema.columns where table_schema='rgsr' and table_name='lab_members' and column_name='user_id') then
    begin
      execute 'alter table rgsr.lab_members add constraint lab_members_unique unique (lab_id, user_id)';
    exception when duplicate_object then null;
    end;
  end if;
end
$do$;

create index if not exists ix_lab_members_lab on rgsr.lab_members(lab_id);
create index if not exists ix_lab_members_user on rgsr.lab_members(user_id);

commit;
-- ============================================================
-- End SUPER PRELUDE
-- ============================================================
