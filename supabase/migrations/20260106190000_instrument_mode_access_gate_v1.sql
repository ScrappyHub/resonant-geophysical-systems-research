-- CORE: instrument-mode access gate (v1)
-- Goal: deny-by-default, invite-only capability, remove Individual Researcher tier issuance
-- NOTE: this is additive + safe; it does NOT assume your existing tier tables.

begin;

-- 1) Access grants table (deny-by-default at app/RLS layer)
create table if not exists public.core_access_grants (
  user_id uuid primary key,
  grant_reason text not null default 'INVITED_EVALUATOR',
  granted_by uuid,
  granted_at timestamptz not null default now(),
  revoked_at timestamptz,
  revoked_by uuid,
  revoke_reason text
);

comment on table public.core_access_grants is
'Instrument-mode gate: user must have an active grant to access CORE capabilities.';

-- 2) Helper: active grant check
create or replace function public.core_has_active_grant(p_user_id uuid)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from public.core_access_grants g
    where g.user_id = p_user_id
      and g.revoked_at is null
  );
$$;

-- 3) Admin-only RPC to grant access (you should wire auth check + audit later)
-- This function exists now so you can route all grants through one governed place.
create or replace function public.core_admin_grant_access(p_user_id uuid, p_reason text)
returns void
language plpgsql
security definer
as $$
begin
  insert into public.core_access_grants(user_id, grant_reason, granted_at)
  values (p_user_id, coalesce(p_reason,'INVITED_EVALUATOR'), now())
  on conflict (user_id) do update
    set grant_reason = excluded.grant_reason,
        revoked_at = null,
        revoked_by = null,
        revoke_reason = null,
        granted_at = now();
end;
$$;

-- 4) Admin-only RPC to revoke access
create or replace function public.core_admin_revoke_access(p_user_id uuid, p_reason text)
returns void
language plpgsql
security definer
as $$
begin
  update public.core_access_grants
     set revoked_at = now(),
         revoke_reason = coalesce(p_reason,'REVOKED')
   where user_id = p_user_id
     and revoked_at is null;
end;
$$;

commit;
