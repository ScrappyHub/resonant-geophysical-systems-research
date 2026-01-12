begin;

-- =============================================================================
-- CORE LAW: governed schemas must not depend on auth.users for identity
-- Introduce core.subjects (PII-zero) and repoint ownership FKs to it
-- =============================================================================

create schema if not exists core;

create table if not exists core.subjects (
  subject_id uuid primary key,
  created_at timestamptz not null default now()
);

-- Deterministic local subject for tests/dev (NO PII)
insert into core.subjects(subject_id)
values ('00000000-0000-0000-0000-000000000001'::uuid)
on conflict do nothing;

-- Drop any existing owner FK on rgsr.engine_runs (name may vary)
do $$
declare
  v_conname text;
begin
  select c.conname into v_conname
  from pg_constraint c
  where c.connamespace = 'rgsr'::regnamespace
    and c.conrelid = 'rgsr.engine_runs'::regclass
    and c.contype = 'f'
    and pg_get_constraintdef(c.oid) ilike '%(owner_uid)%';

  if v_conname is not null then
    execute format('alter table rgsr.engine_runs drop constraint %I', v_conname);
  end if;
end
$$;

-- Add the compliant FK to core.subjects
alter table rgsr.engine_runs
  add constraint engine_runs_owner_uid_subject_fkey
  foreign key (owner_uid)
  references core.subjects(subject_id);

commit;
