-- 20260102061525_local_noop_placeholder.sql
-- LOCAL/SHADOW SAFE CANONICALIZATION:
-- Remote has version 20260102061525 in migration history.
-- Locally we must also create the minimal canonical objects it introduced,
-- otherwise later migrations (20260103200531...) fail.

do $$
begin
  raise notice 'LOCAL 20260102061525 canonical placeholder: ensuring rgsr.admin_uids exists (safe)';
end
$$;

-- Ensure schema exists
create schema if not exists rgsr;

-- Ensure table exists
create table if not exists rgsr.admin_uids (
  uid uuid primary key references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

-- RLS
alter table rgsr.admin_uids enable row level security;

-- Policies (create only if missing)
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'rgsr' and tablename = 'admin_uids' and policyname = 'admin_uids_read'
  ) then
    execute $p$
      create policy admin_uids_read
      on rgsr.admin_uids
      for select
      using (
        auth.uid() = uid
        or exists (select 1 from rgsr.admin_uids a where a.uid = auth.uid())
      )
    $p$;
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'rgsr' and tablename = 'admin_uids' and policyname = 'admin_uids_admin'
  ) then
    execute $p$
      create policy admin_uids_admin
      on rgsr.admin_uids
      for all
      using (exists (select 1 from rgsr.admin_uids a where a.uid = auth.uid()))
      with check (exists (select 1 from rgsr.admin_uids a where a.uid = auth.uid()))
    $p$;
  end if;
end
$$;

-- Shadow/local-safe seed: only insert if the uid exists in auth.users
with u(uid) as (
  values
    ('d4ca5da1-b30a-44af-8b7e-2fd0fbc0bd2d'::uuid),
    ('ee11a221-cb04-4472-92f1-08534e1dd9e7'::uuid),
    ('ee9cd604-09ca-43c1-9738-5591efb65c2d'::uuid),
    ('57ea797c-a3ce-4c06-8da3-c6c7b9f5757c'::uuid),
    ('9186100f-f607-404e-8c18-24b457ca0ee4'::uuid)
)
insert into rgsr.admin_uids(uid)
select u.uid
from u
join auth.users au on au.id = u.uid
on conflict (uid) do nothing;

do $$
begin
  raise notice 'LOCAL 20260102061525 canonical placeholder: done';
end
$$;