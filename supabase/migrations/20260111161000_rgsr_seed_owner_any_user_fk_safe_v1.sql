-- 20260111161000_rgsr_seed_owner_any_user_fk_safe_v1.sql
-- CANONICAL: make rgsr._seed_owner_any_user() FK-safe for core.subjects(subject_id)
-- Policy:
--   - NEVER return a uid that violates rgsr.engine_runs.owner_uid FK.
--   - Prefer a stable deterministic test subject id (noise-free tests).
--   - Allow an explicit "random" mode for ad-hoc local usage.

begin;

create schema if not exists rgsr;
create schema if not exists core;

-- Optional helper: detect "local-ish" environments (best-effort).
-- We keep this conservative and do NOT rely on it for correctness.
create or replace function rgsr._is_local_env()
returns boolean
language sql
stable
as $$
  select coalesce(current_setting('app.environment', true), '') in ('local','dev','development')
$$;

create or replace function rgsr._seed_owner_any_user()
returns uuid
language plpgsql
security definer
set search_path = public, rgsr, core
as $$
declare
  v_user uuid;
  v_mode text;
begin
  /*
    Mode control:
      - If app.seed_owner_mode is set to 'random', we generate a random uuid.
      - Otherwise we return a stable deterministic uuid.
    This keeps determinism tests stable but still lets you opt-in to random.

    You can set this in a session if needed:
      select set_config('app.seed_owner_mode','random', true);
  */

  v_mode := coalesce(current_setting('app.seed_owner_mode', true), '');

  if lower(v_mode) = 'random' then
    v_user := gen_random_uuid();
  else
    -- Stable deterministic test subject id (canonical)
    v_user := 'd4ca5da1-b30a-44af-8b7e-2fd0fbc0bd2d'::uuid;
  end if;

  -- FK satisfier: engine_runs.owner_uid -> core.subjects(subject_id)
  insert into core.subjects(subject_id)
  values (v_user)
  on conflict (subject_id) do nothing;

  return v_user;
end;
$$;

commit;
