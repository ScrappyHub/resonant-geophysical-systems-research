-- ============================================================
-- RGSR v10.1 FIX SAFE REPAIR (replaces quarantined 02709)
-- Goal: ensure lab_members invariants without constraint-name collisions.
-- - Ensures columns exist
-- - Ensures role check exists (by definition match)
-- - Ensures UNIQUE coverage of (lab_id,user_id) via unique index if needed
-- ============================================================

begin;

-- minimal safety: tables should already exist by v10, but never assume
create table if not exists rgsr.labs (lab_id uuid primary key default gen_random_uuid());
create table if not exists rgsr.lab_members (membership_id uuid primary key default gen_random_uuid(), lab_id uuid null, user_id uuid null);

-- 1) normalize lab_members columns
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
end
$do$;

-- 2) role check constraint: add only if no equivalent check exists
do $do$
declare v_exists boolean;
begin
  select exists(
    select 1
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'rgsr' and t.relname = 'lab_members' and c.contype = 'c'
      and pg_get_constraintdef(c.oid) like '%member_role%OWNER%ADMIN%MEMBER%VIEWER%'
  ) into v_exists;

  if not v_exists then
    begin
      execute 'alter table rgsr.lab_members add constraint lab_members_role_chk_v10repair check (member_role in (''OWNER'',''ADMIN'',''MEMBER'',''VIEWER''))';
    exception when duplicate_object then null;
    end;
  end if;
end
$do$;

-- 3) uniqueness: if any UNIQUE index/constraint covers both columns, do nothing; else create safe unique index
do $do$
declare v_has_unique boolean;
begin
  select exists(
    select 1
    from pg_index i
    join pg_class t on t.oid = i.indrelid
    join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'rgsr' and t.relname = 'lab_members'
      and i.indisunique = true
      and (
        select count(*)
        from unnest(i.indkey) k(attnum)
        join pg_attribute a on a.attrelid = t.oid and a.attnum = k.attnum
        where a.attname in ('lab_id','user_id')
      ) = 2
  ) into v_has_unique;

  if not v_has_unique then
    begin
      execute 'create unique index if not exists ux_lab_members_lab_user_v10repair on rgsr.lab_members(lab_id, user_id)';
    exception when duplicate_object then null;
    end;
  end if;
end
$do$;

create index if not exists ix_lab_members_lab on rgsr.lab_members(lab_id);
create index if not exists ix_lab_members_user on rgsr.lab_members(user_id);

commit;
-- ============================================================
-- End SAFE REPAIR
-- ============================================================
