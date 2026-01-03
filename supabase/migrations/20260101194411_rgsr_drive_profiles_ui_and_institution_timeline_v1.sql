-- ============================================================
-- RGSR: Drive Profiles UI RPC (computed C/F) + Institution App Timeline (audit trail)
-- Canonical rewrite: tagged dollar-quoting + semicolons everywhere
-- ============================================================

begin;

-- 0) Temp conversion helpers
create or replace function rgsr.c_to_f(p_c numeric) returns numeric
language sql immutable as $sql$
  select (p_c * 9.0/5.0) + 32.0;
$sql$;

create or replace function rgsr.f_to_c(p_f numeric) returns numeric
language sql immutable as $sql$
  select (p_f - 32.0) * 5.0/9.0;
$sql$;

-- 1) Drive Profiles UI RPC
create or replace function rgsr._apply_temp_unit_to_drive_json(p_drive jsonb, p_unit text)
returns jsonb
language plpgsql
stable as $plpgsql$
declare
  outj jsonb := p_drive;
  v numeric;
begin
  if p_drive is null then
    return null;
  end if;

  if jsonb_typeof(outj->'units') = 'object' then
    outj := jsonb_set(outj, '{units,temp}', to_jsonb(p_unit), true);
  else
    outj := jsonb_set(outj, '{units}', jsonb_build_object('temp', p_unit), true);
  end if;

  if p_unit <> 'F' then
    return outj;
  end if;

  if (outj #>> '{external_conditions,ambient_temp_c}') is not null then
    v := (outj #>> '{external_conditions,ambient_temp_c}')::numeric;
    outj := jsonb_set(outj, '{external_conditions,ambient_temp_f}', to_jsonb(rgsr.c_to_f(v)), true);
  end if;

  if (outj #>> '{internal_chamber,chamber_temp_c}') is not null then
    v := (outj #>> '{internal_chamber,chamber_temp_c}')::numeric;
    outj := jsonb_set(outj, '{internal_chamber,chamber_temp_f}', to_jsonb(rgsr.c_to_f(v)), true);
  end if;

  if (outj #>> '{water_domain,water_temp_c}') is not null then
    v := (outj #>> '{water_domain,water_temp_c}')::numeric;
    outj := jsonb_set(outj, '{water_domain,water_temp_f}', to_jsonb(rgsr.c_to_f(v)), true);
  end if;

  return outj;
end;
$plpgsql$;

create or replace function rgsr.get_drive_profiles_ui(p_lab uuid default null)
returns jsonb
language sql
stable as $sql$
  with pref as (
    select coalesce((select p.temp_unit::text from rgsr.user_preferences p where p.user_id = auth.uid()), 'C') as unit
  ), profiles as (
    select
      dp.drive_profile_id, dp.name, dp.description, dp.lane::text as lane, dp.is_template,
      dp.engine_code, dp.owner_id, dp.lab_id, dp.created_at, dp.updated_at,
      dp.drive_json as drive_json_raw,
      rgsr._apply_temp_unit_to_drive_json(dp.drive_json, (select unit from pref)) as drive_json_computed
    from rgsr.drive_profiles dp
    where rgsr.can_read_drive_profile(dp.lane, dp.owner_id, dp.lab_id)
      and (p_lab is null or dp.lab_id = p_lab or dp.lab_id is null)
  )
  select jsonb_build_object(
    'temp_unit', (select unit from pref),
    'profiles', coalesce((
      select jsonb_agg(jsonb_build_object(
        'drive_profile_id', p.drive_profile_id,
        'name', p.name,
        'description', p.description,
        'lane', p.lane,
        'is_template', p.is_template,
        'engine_code', p.engine_code,
        'owner_id', p.owner_id,
        'lab_id', p.lab_id,
        'created_at', p.created_at,
        'updated_at', p.updated_at,
        'drive_json_raw', p.drive_json_raw,
        'drive_json_computed', p.drive_json_computed
      ) order by (p.is_template) desc, p.updated_at desc)
      from profiles p
    ), '[]'::jsonb)
  );
$sql$;

grant execute on function rgsr.get_drive_profiles_ui(uuid) to authenticated;

-- 2) Institution Application Event Log (timeline)
create table if not exists rgsr.institution_application_events (
  event_id uuid primary key default gen_random_uuid(),
  application_id uuid not null references rgsr.institution_access_applications(application_id) on delete cascade,
  actor_user_id uuid references auth.users(id) on delete set null,
  event_type text not null,
  from_status text,
  to_status text,
  note text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists ix_inst_app_events_app_time
  on rgsr.institution_application_events(application_id, created_at asc);

alter table rgsr.institution_application_events enable row level security;

drop policy if exists inst_ev_select on rgsr.institution_application_events;
create policy inst_ev_select on rgsr.institution_application_events for select to authenticated
using (
  rgsr.is_sys_admin()
  or exists (
    select 1 from rgsr.institution_access_applications a
    where a.application_id = institution_application_events.application_id
      and a.applicant_user_id = auth.uid()
  )
);

drop policy if exists inst_ev_insert on rgsr.institution_application_events;
create policy inst_ev_insert on rgsr.institution_application_events for insert to authenticated
with check (rgsr.is_sys_admin() or rgsr.is_service_role());

drop policy if exists inst_ev_update on rgsr.institution_application_events;
create policy inst_ev_update on rgsr.institution_application_events for update to authenticated
using (false) with check (false);

drop policy if exists inst_ev_delete on rgsr.institution_application_events;
create policy inst_ev_delete on rgsr.institution_application_events for delete to authenticated
using (false);

create or replace function rgsr._log_institution_app_event(
  p_app uuid,
  p_type text,
  p_from text,
  p_to text,
  p_note text default null,
  p_meta jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
set search_path = rgsr, public, auth as $plpgsql$
begin
  insert into rgsr.institution_application_events(application_id, actor_user_id, event_type, from_status, to_status, note, metadata)
  values (p_app, auth.uid(), p_type, p_from, p_to, p_note, coalesce(p_meta, '{}'::jsonb));
end;
$plpgsql$;

revoke all on function rgsr._log_institution_app_event(uuid, text, text, text, text, jsonb) from public;
grant execute on function rgsr._log_institution_app_event(uuid, text, text, text, text, jsonb) to authenticated;

create or replace function rgsr.tg_institution_app_timeline()
returns trigger
language plpgsql as $plpgsql$
begin
  if (tg_op = 'INSERT') then
    perform rgsr._log_institution_app_event(new.application_id, 'CREATED', null, new.status::text, null, jsonb_build_object('org_name', new.org_name));
    if new.status::text = 'SUBMITTED' then
      perform rgsr._log_institution_app_event(new.application_id, 'SUBMITTED', 'DRAFT', 'SUBMITTED', null, '{}'::jsonb);
    end if;
    return new;
  end if;

  if (tg_op = 'UPDATE') then
    if new.status is distinct from old.status then
      perform rgsr._log_institution_app_event(new.application_id, 'STATUS_CHANGED', old.status::text, new.status::text, new.decision_reason, '{}'::jsonb);
    end if;

    if new.billing_verified_at is distinct from old.billing_verified_at and new.billing_verified_at is not null then
      perform rgsr._log_institution_app_event(
        new.application_id, 'BILLING_VERIFIED',
        coalesce(old.status::text, null), coalesce(new.status::text, null),
        null,
        jsonb_build_object('provider', new.billing_provider, 'customer_id', new.billing_customer_id, 'subscription_id', new.billing_subscription_id)
      );
    end if;

    if new.activated_at is distinct from old.activated_at and new.activated_at is not null then
      perform rgsr._log_institution_app_event(new.application_id, 'ACTIVATED', coalesce(old.status::text, null), coalesce(new.status::text, null), null, '{}'::jsonb);
    end if;

    return new;
  end if;

  return new;
end;
$plpgsql$;

do $sql$
begin
  if not exists (select 1 from pg_trigger where tgname = 'tr_inst_apps_timeline') then
    create trigger tr_inst_apps_timeline
    after insert or update on rgsr.institution_access_applications
    for each row execute function rgsr.tg_institution_app_timeline();
  end if;
end
$sql$;

create or replace function rgsr.get_my_institution_application_timeline(p_application_id uuid)
returns jsonb
language sql
stable as $sql$
  select jsonb_build_object(
    'application_id', p_application_id,
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_id', e.event_id,
        'event_type', e.event_type,
        'from_status', e.from_status,
        'to_status', e.to_status,
        'note', e.note,
        'metadata', e.metadata,
        'actor_user_id', e.actor_user_id,
        'created_at', e.created_at
      ) order by e.created_at asc)
      from rgsr.institution_application_events e
      where e.application_id = p_application_id
    ), '[]'::jsonb)
  );
$sql$;

grant execute on function rgsr.get_my_institution_application_timeline(uuid) to authenticated;

commit;

-- ============================================================
-- End migration
-- ============================================================
