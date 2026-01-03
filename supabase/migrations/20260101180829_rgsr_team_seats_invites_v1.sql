-- ============================================================
-- RGSR: Team Seats + Invites + Private Team Management (V1)
-- Canonical: per-lab roles ("seats"), invite workflow, RLS locked
-- No public team data; lab membership is private to that lab.
-- ============================================================

begin;

create extension if not exists pgcrypto;

-- 1) Enums
do $$
begin
  if not exists (select 1 from pg_type where typname = 'rgsr_lab_role') then
    create type rgsr.rgsr_lab_role as enum ('OWNER','ADMIN','MEMBER','VIEWER');
  end if;

  if not exists (select 1 from pg_type where typname = 'rgsr_invite_status') then
    create type rgsr.rgsr_invite_status as enum ('PENDING','ACCEPTED','REVOKED','EXPIRED');
  end if;
end$$;

-- 2) Capabilities (team + profile)
insert into rgsr.capabilities (capability_id, description) values
  ('PROFILE_EDIT',        'Edit your own profile'),
  ('TEAM_VIEW',           'View lab team roster (private to lab)'),
  ('TEAM_INVITE',         'Invite members to your lab'),
  ('TEAM_MANAGE',         'Manage lab seats/roles/remove members'),
  ('LAB_EDIT',            'Edit lab metadata/settings' )
on conflict do nothing;

-- 3) Lab role -> capabilities (seat capabilities)
create table if not exists rgsr.lab_role_capabilities (
  lab_role      rgsr.rgsr_lab_role not null,
  capability_id text not null references rgsr.capabilities(capability_id) on delete cascade,
  enabled       boolean not null default true,
  primary key (lab_role, capability_id)
);

-- Seed: VIEWER can only TEAM_VIEW; MEMBER can TEAM_VIEW; ADMIN can TEAM_*; OWNER full team + lab edit
insert into rgsr.lab_role_capabilities (lab_role, capability_id, enabled) values
  ('VIEWER','TEAM_VIEW', true),
  ('MEMBER','TEAM_VIEW', true),
  ('ADMIN','TEAM_VIEW', true),
  ('ADMIN','TEAM_INVITE', true),
  ('ADMIN','TEAM_MANAGE', true),
  ('OWNER','TEAM_VIEW', true),
  ('OWNER','TEAM_INVITE', true),
  ('OWNER','TEAM_MANAGE', true),
  ('OWNER','LAB_EDIT', true)
on conflict do nothing;

-- 4) Ensure user_profiles supports self-edit (capability-based)
-- If you want PROFILE_EDIT by plan/role, seed it here for all authenticated plans:
insert into rgsr.plan_capabilities(plan_id, capability_id, enabled)
select p.plan_id, 'PROFILE_EDIT', true
from (values
  ('OBSERVER_FREE'::rgsr.rgsr_plan_id),
  ('RESEARCHER_PRO'::rgsr.rgsr_plan_id),
  ('LAB_STANDARD'::rgsr.rgsr_plan_id),
  ('INSTITUTION'::rgsr.rgsr_plan_id)
) as p(plan_id)
on conflict do nothing;

-- 5) Upgrade lab_members into true "seats": add seat_role + make it canonical
alter table rgsr.lab_members add column if not exists seat_role rgsr.rgsr_lab_role;

-- Backfill seat_role from existing is_admin / ownership (safe idempotent)
update rgsr.lab_members lm
set seat_role = case
  when lm.seat_role is not null then lm.seat_role
  when lm.is_admin is true then 'ADMIN'::rgsr.rgsr_lab_role
  else 'MEMBER'::rgsr.rgsr_lab_role
end
where lm.seat_role is null;

-- Ensure lab owner always has OWNER seat (creates if missing)
insert into rgsr.lab_members (lab_id, user_id, is_admin, created_at, seat_role)
select l.lab_id, l.owner_id, true, now(), 'OWNER'::rgsr.rgsr_lab_role
from rgsr.labs l
where not exists (
  select 1 from rgsr.lab_members lm
  where lm.lab_id = l.lab_id and lm.user_id = l.owner_id
)
on conflict do nothing;

-- Enforce NOT NULL after backfill (safe)
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'rgsr' and table_name = 'lab_members' and column_name = 'seat_role'
               and is_nullable = 'YES') then
    -- Only set NOT NULL if no nulls remain
    if not exists (select 1 from rgsr.lab_members where seat_role is null) then
      alter table rgsr.lab_members alter column seat_role set not null;
    end if;
  end if;
end$$;

-- 6) Seat capability checks (per lab)
create or replace function rgsr.current_lab_role(p_lab uuid)
returns rgsr.rgsr_lab_role
language sql stable as $$
  select
    case
      when exists (select 1 from rgsr.labs l where l.lab_id = p_lab and l.owner_id = auth.uid()) then 'OWNER'::rgsr.rgsr_lab_role
      else coalesce((select lm.seat_role from rgsr.lab_members lm where lm.lab_id = p_lab and lm.user_id = auth.uid()), 'VIEWER'::rgsr.rgsr_lab_role)
    end;
$$;

create or replace function rgsr.has_lab_capability(p_lab uuid, p_cap text)
returns boolean
language sql stable as $$
  select rgsr.is_sys_admin()
  or exists (
    select 1
    from rgsr.lab_role_capabilities lrc
    where lrc.lab_role = rgsr.current_lab_role(p_lab)
      and lrc.capability_id = p_cap
      and lrc.enabled
  );
$$;

create or replace function rgsr.can_manage_lab(p_lab uuid)
returns boolean
language sql stable as $$
  select rgsr.has_lab_capability(p_lab, 'TEAM_MANAGE')
      or rgsr.has_lab_capability(p_lab, 'LAB_EDIT');
$$;

-- 7) Lab invites (private to lab admins/owner)
create table if not exists rgsr.lab_invites (
  invite_id      uuid primary key default gen_random_uuid(),
  lab_id         uuid not null references rgsr.labs(lab_id) on delete cascade,
  email          text not null,
  seat_role      rgsr.rgsr_lab_role not null default 'MEMBER',
  status         rgsr.rgsr_invite_status not null default 'PENDING',
  token_sha256   text not null,
  created_by     uuid not null references auth.users(id) on delete cascade,
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null default (now() + interval '7 days'),
  accepted_at    timestamptz,
  accepted_by    uuid references auth.users(id) on delete set null,
  revoked_at     timestamptz,
  unique(lab_id, email, status)
);

create index if not exists idx_lab_invites_lab_id on rgsr.lab_invites(lab_id);
create index if not exists idx_lab_invites_token_sha on rgsr.lab_invites(token_sha256);

-- 8) Invite RPCs (canonical one-shot, no exposing token hash)
create or replace function rgsr.create_lab_invite(p_lab uuid, p_email text, p_seat_role rgsr.rgsr_lab_role default 'MEMBER')
returns table(invite_id uuid, invite_token text, expires_at timestamptz)
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
declare
  raw_token text;
  token_hash text;
  out_id uuid;
  out_exp timestamptz;
begin
  if p_email is null or length(trim(p_email)) = 0 then
    raise exception 'email is required' using errcode = 'invalid_parameter_value';
  end if;

  if not rgsr.has_lab_capability(p_lab, 'TEAM_INVITE') then
    raise exception 'not authorized to invite' using errcode = 'insufficient_privilege';
  end if;

  -- token: 32 bytes random -> hex
  raw_token := encode(gen_random_bytes(32), 'hex');
  token_hash := encode(digest(raw_token, 'sha256'), 'hex');

  insert into rgsr.lab_invites(lab_id, email, seat_role, status, token_sha256, created_by, expires_at)
  values (p_lab, lower(trim(p_email)), p_seat_role, 'PENDING', token_hash, auth.uid(), now() + interval '7 days')
  returning rgsr.lab_invites.invite_id, rgsr.lab_invites.expires_at into out_id, out_exp;

  return query select out_id, raw_token, out_exp;
end;
$$;

create or replace function rgsr.accept_lab_invite(p_token text)
returns table(lab_id uuid, seat_role rgsr.rgsr_lab_role)
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
declare
  token_hash text;
  inv record;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    raise exception 'token is required' using errcode = 'invalid_parameter_value';
  end if;

  token_hash := encode(digest(p_token, 'sha256'), 'hex');

  select * into inv
  from rgsr.lab_invites li
  where li.token_sha256 = token_hash
    and li.status = 'PENDING'
  limit 1;

  if not found then
    raise exception 'invite not found or not pending' using errcode = 'invalid_parameter_value';
  end if;

  if inv.expires_at < now() then
    update rgsr.lab_invites set status = 'EXPIRED' where invite_id = inv.invite_id;
    raise exception 'invite expired' using errcode = 'invalid_parameter_value';
  end if;

  -- attach seat
  insert into rgsr.lab_members(lab_id, user_id, is_admin, created_at, seat_role)
  values (inv.lab_id, auth.uid(), (inv.seat_role in ('OWNER','ADMIN')), now(), inv.seat_role)
  on conflict (lab_id, user_id) do update
    set seat_role = excluded.seat_role,
        is_admin = excluded.is_admin;

  update rgsr.lab_invites
  set status = 'ACCEPTED', accepted_at = now(), accepted_by = auth.uid()
  where invite_id = inv.invite_id;

  return query select inv.lab_id, inv.seat_role;
end;
$$;

create or replace function rgsr.revoke_lab_invite(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $$
declare
  inv record;
begin
  select * into inv from rgsr.lab_invites where invite_id = p_invite_id;
  if not found then
    return;
  end if;

  if not rgsr.has_lab_capability(inv.lab_id, 'TEAM_INVITE') then
    raise exception 'not authorized to revoke' using errcode = 'insufficient_privilege';
  end if;

  update rgsr.lab_invites
  set status = 'REVOKED', revoked_at = now()
  where invite_id = p_invite_id and status = 'PENDING';
end;
$$;

-- 9) Private "my profile" view for UI Profile menu
create or replace view rgsr.v_my_profile as
select
  up.user_id,
  up.display_name,
  up.role_id,
  up.plan_id,
  (
    select coalesce(jsonb_agg(jsonb_build_object(
      'lab_id', l.lab_id,
      'name', l.name,
      'seat_role', rgsr.current_lab_role(l.lab_id)
    ) order by l.created_at), '[]'::jsonb)
    from rgsr.labs l
    where exists (
      select 1 from rgsr.lab_members lm
      where lm.lab_id = l.lab_id and lm.user_id = auth.uid()
    ) or l.owner_id = auth.uid()
  ) as labs
from rgsr.user_profiles up
where up.user_id = auth.uid();

-- 10) RLS: lock team data to the lab
alter table rgsr.lab_invites enable row level security;

-- lab_members: allow only members of that lab to see roster (private), and only admins/owner to modify
drop policy if exists lm_select on rgsr.lab_members;
create policy lm_select on rgsr.lab_members for select to authenticated
using (
  rgsr.is_sys_admin()
  or rgsr.is_lab_member(lab_id)
);

drop policy if exists lm_insert on rgsr.lab_members;
create policy lm_insert on rgsr.lab_members for insert to authenticated
with check (
  rgsr.is_sys_admin()
  or rgsr.has_lab_capability(lab_id, 'TEAM_MANAGE')
);

drop policy if exists lm_update on rgsr.lab_members;
create policy lm_update on rgsr.lab_members for update to authenticated
using (
  rgsr.is_sys_admin()
  or rgsr.has_lab_capability(lab_id, 'TEAM_MANAGE')
)
with check (
  rgsr.is_sys_admin()
  or rgsr.has_lab_capability(lab_id, 'TEAM_MANAGE')
);

drop policy if exists lm_delete on rgsr.lab_members;
create policy lm_delete on rgsr.lab_members for delete to authenticated
using (
  rgsr.is_sys_admin()
  or rgsr.has_lab_capability(lab_id, 'TEAM_MANAGE')
);

-- labs: members can see their lab; only OWNER/ADMIN can edit lab metadata
drop policy if exists labs_select on rgsr.labs;
create policy labs_select on rgsr.labs for select to authenticated
using (
  rgsr.is_sys_admin()
  or owner_id = auth.uid()
  or exists (select 1 from rgsr.lab_members lm where lm.lab_id = labs.lab_id and lm.user_id = auth.uid())
);

drop policy if exists labs_update on rgsr.labs;
create policy labs_update on rgsr.labs for update to authenticated
using (
  rgsr.is_sys_admin()
  or owner_id = auth.uid()
  or rgsr.has_lab_capability(labs.lab_id, 'LAB_EDIT')
)
with check (
  rgsr.is_sys_admin()
  or owner_id = auth.uid()
  or rgsr.has_lab_capability(labs.lab_id, 'LAB_EDIT')
);

-- invites: only lab admins/owner can view/manage invites (still private)
drop policy if exists li_select on rgsr.lab_invites;
create policy li_select on rgsr.lab_invites for select to authenticated
using (
  rgsr.is_sys_admin()
  or rgsr.has_lab_capability(lab_id, 'TEAM_INVITE')
);

drop policy if exists li_insert on rgsr.lab_invites;
create policy li_insert on rgsr.lab_invites for insert to authenticated
with check (
  rgsr.is_sys_admin()
  or rgsr.has_lab_capability(lab_id, 'TEAM_INVITE')
);

drop policy if exists li_update on rgsr.lab_invites;
create policy li_update on rgsr.lab_invites for update to authenticated
using (
  rgsr.is_sys_admin()
  or rgsr.has_lab_capability(lab_id, 'TEAM_INVITE')
)
with check (
  rgsr.is_sys_admin()
  or rgsr.has_lab_capability(lab_id, 'TEAM_INVITE')
);

-- user_profiles: user can edit self fields (display_name) privately
-- (Your existing policies already allow self update; we keep them.)

commit;

-- ============================================================
-- End migration
-- ============================================================
