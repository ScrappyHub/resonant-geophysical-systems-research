begin;

-- ============================================================
-- RGSR: NODE SNAPSHOT + NODE HASH + SEALED TAMPER GUARDS (V1)
-- Option A: snapshot nodes so replay/attestation never depends
--           on mutable live tables.
--
-- Adds:
--  - rgsr.engine_run_nodes_snapshot
--  - rgsr.snapshot_engine_run_nodes(uuid)
--  - rgsr.engine_run_nodes_hash_sha256(uuid)
--  - tamper triggers on rgsr.engine_run_nodes after seal
--  - tamper triggers on snapshot table after seal
--  - extends rgsr.v_engine_run_attestation with nodes proof
-- ============================================================

create extension if not exists pgcrypto;

-- ----------------------------
-- 0) Snapshot table
-- ----------------------------
create table if not exists rgsr.engine_run_nodes_snapshot (
  run_id     uuid not null references rgsr.engine_runs(run_id) on delete cascade,
  node_id    text not null,
  position   jsonb not null default '{}'::jsonb,
  measures   text[] not null default '{}'::text[],
  metadata   jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  primary key (run_id, node_id)
);

comment on table rgsr.engine_run_nodes_snapshot is
'Canonical snapshot of engine_run_nodes for a run. Written once (pre-seal) and immutable after seal. Used for proof/attestation and future replay hardening.';

-- ----------------------------
-- 1) Guard function for nodes tables
-- ----------------------------
create or replace function rgsr.guard_engine_run_nodes_mutation_after_seal()
returns trigger
language plpgsql
security definer
set search_path to 'rgsr','public'
as $function$
declare
  v_run_id uuid;
  v_seal   text;
begin
  -- Determine run_id from row
  v_run_id := coalesce(NEW.run_id, OLD.run_id);

  if v_run_id is null then
    raise exception 'NODES_MUTATION_WITHOUT_RUN_ID';
  end if;

  select seal_hash_sha256
    into v_seal
  from rgsr.engine_runs
  where run_id = v_run_id;

  -- Strong integrity: block if run missing
  if not found then
    raise exception 'NODES_MUTATION_RUN_NOT_FOUND run_id=%', v_run_id;
  end if;

  -- If sealed, block all writes
  if v_seal is not null and v_seal <> '' then
    raise exception 'ENGINE_RUN_IS_SEALED: mutations forbidden for run_id=%', v_run_id;
  end if;

  if TG_OP = 'DELETE' then
    return OLD;
  else
    return NEW;
  end if;
end;
$function$;

comment on function rgsr.guard_engine_run_nodes_mutation_after_seal() is
'Blocks INSERT/UPDATE/DELETE on node tables once engine_runs.seal_hash_sha256 is set for the run.';

-- ----------------------------
-- 2) Attach triggers to live nodes table (rgsr.engine_run_nodes)
--    (This table previously had no triggers; we add them.)
-- ----------------------------
do $$
begin
  if exists (
    select 1
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname='rgsr' and c.relname='engine_run_nodes'
  ) then

    -- Drop if they exist (idempotent)
    if exists (select 1 from pg_trigger where tgname='tr_engine_run_nodes_block_insert_after_seal') then
      execute 'drop trigger tr_engine_run_nodes_block_insert_after_seal on rgsr.engine_run_nodes';
    end if;
    if exists (select 1 from pg_trigger where tgname='tr_engine_run_nodes_block_update_after_seal') then
      execute 'drop trigger tr_engine_run_nodes_block_update_after_seal on rgsr.engine_run_nodes';
    end if;
    if exists (select 1 from pg_trigger where tgname='tr_engine_run_nodes_block_delete_after_seal') then
      execute 'drop trigger tr_engine_run_nodes_block_delete_after_seal on rgsr.engine_run_nodes';
    end if;

    execute $q$
      create trigger tr_engine_run_nodes_block_insert_after_seal
      before insert on rgsr.engine_run_nodes
      for each row execute function rgsr.guard_engine_run_nodes_mutation_after_seal()
    $q$;

    execute $q$
      create trigger tr_engine_run_nodes_block_update_after_seal
      before update on rgsr.engine_run_nodes
      for each row execute function rgsr.guard_engine_run_nodes_mutation_after_seal()
    $q$;

    execute $q$
      create trigger tr_engine_run_nodes_block_delete_after_seal
      before delete on rgsr.engine_run_nodes
      for each row execute function rgsr.guard_engine_run_nodes_mutation_after_seal()
    $q$;

  end if;
end $$;

-- ----------------------------
-- 3) Attach triggers to snapshot table too
--    (Snapshot should be immutable after seal.)
-- ----------------------------
do $$
begin
  -- Drop if they exist (idempotent)
  if exists (select 1 from pg_trigger where tgname='tr_engine_run_nodes_snapshot_block_insert_after_seal') then
    execute 'drop trigger tr_engine_run_nodes_snapshot_block_insert_after_seal on rgsr.engine_run_nodes_snapshot';
  end if;
  if exists (select 1 from pg_trigger where tgname='tr_engine_run_nodes_snapshot_block_update_after_seal') then
    execute 'drop trigger tr_engine_run_nodes_snapshot_block_update_after_seal on rgsr.engine_run_nodes_snapshot';
  end if;
  if exists (select 1 from pg_trigger where tgname='tr_engine_run_nodes_snapshot_block_delete_after_seal') then
    execute 'drop trigger tr_engine_run_nodes_snapshot_block_delete_after_seal on rgsr.engine_run_nodes_snapshot';
  end if;

  execute $q$
    create trigger tr_engine_run_nodes_snapshot_block_insert_after_seal
    before insert on rgsr.engine_run_nodes_snapshot
    for each row execute function rgsr.guard_engine_run_nodes_mutation_after_seal()
  $q$;

  execute $q$
    create trigger tr_engine_run_nodes_snapshot_block_update_after_seal
    before update on rgsr.engine_run_nodes_snapshot
    for each row execute function rgsr.guard_engine_run_nodes_mutation_after_seal()
  $q$;

  execute $q$
    create trigger tr_engine_run_nodes_snapshot_block_delete_after_seal
    before delete on rgsr.engine_run_nodes_snapshot
    for each row execute function rgsr.guard_engine_run_nodes_mutation_after_seal()
  $q$;
end $$;

-- ----------------------------
-- 4) Snapshot function (idempotent)
-- ----------------------------
create or replace function rgsr.snapshot_engine_run_nodes(p_run_id uuid)
returns int
language plpgsql
security definer
set search_path to 'rgsr','public'
as $function$
declare
  v_owner uuid;
  v_seal  text;
  v_ins   int := 0;
begin
  select owner_uid, seal_hash_sha256
    into v_owner, v_seal
  from rgsr.engine_runs
  where run_id = p_run_id;

  if v_owner is null then
    raise exception 'RUN_NOT_FOUND' using errcode='22023';
  end if;

  -- Permission model mirrors step function pattern
  if v_owner <> rgsr.actor_uid() and not rgsr.can_write() then
    raise exception 'FORBIDDEN' using errcode='28000';
  end if;

  -- If sealed, snapshot insert will be blocked by trigger anyway.
  -- But we fail fast with a clearer message.
  if v_seal is not null and v_seal <> '' then
    raise exception 'ENGINE_RUN_IS_SEALED: snapshot forbidden for run_id=%', p_run_id;
  end if;

  -- Only insert missing rows (idempotent)
  insert into rgsr.engine_run_nodes_snapshot(run_id, node_id, position, measures, metadata, created_at)
  select n.run_id, n.node_id, n.position, n.measures, n.metadata, now()
  from rgsr.engine_run_nodes n
  where n.run_id = p_run_id
    and not exists (
      select 1
      from rgsr.engine_run_nodes_snapshot s
      where s.run_id = n.run_id and s.node_id = n.node_id
    );

  get diagnostics v_ins = row_count;

  return v_ins;
end;
$function$;

comment on function rgsr.snapshot_engine_run_nodes(uuid) is
'Snapshots rgsr.engine_run_nodes into rgsr.engine_run_nodes_snapshot for p_run_id. Must be executed pre-seal. Idempotent.';

-- ----------------------------
-- 5) Nodes hash function
--    Deterministic over snapshot if present; else live nodes.
-- ----------------------------
create or replace function rgsr.engine_run_nodes_hash_sha256(p_run_id uuid)
returns text
language sql
stable
as $function$
  with has_snapshot as (
    select 1 as yes
    where exists (
      select 1 from rgsr.engine_run_nodes_snapshot s where s.run_id = p_run_id
    )
  ),
  rows as (
    select
      s.node_id,
      s.position,
      s.measures,
      s.metadata
    from rgsr.engine_run_nodes_snapshot s
    where s.run_id = p_run_id

    union all

    select
      n.node_id,
      n.position,
      n.measures,
      n.metadata
    from rgsr.engine_run_nodes n
    where n.run_id = p_run_id
      and not exists (select 1 from has_snapshot)
  )
  select encode(
    extensions.digest(
      convert_to(
        coalesce(
          string_agg(
            (
              coalesce(node_id::text,'') || ':' ||
              coalesce(position::text,'') || ':' ||
              coalesce(measures::text,'') || ':' ||
              coalesce(metadata::text,'')
            ),
            '|' order by node_id asc
          ),
          ''
        ),
        'utf8'
      ),
      'sha256'
    ),
    'hex'
  )
  from rows;
$function$;

comment on function rgsr.engine_run_nodes_hash_sha256(uuid) is
'Deterministic SHA-256 hash of a run’s node set (snapshot preferred, else live). Order: node_id asc.';

-- ----------------------------
-- 6) Attestation view upgrade (DROP + CREATE)
--     IMPORTANT: CREATE OR REPLACE VIEW cannot remove columns.
--     We drop first to guarantee one-shot green.
-- ----------------------------
drop view if exists rgsr.v_engine_run_attestation cascade;

create view rgsr.v_engine_run_attestation as
select
  r.run_id,
  r.owner_uid,
  r.config_id,
  r.engine_kind,
  r.status,
  r.started_at,
  r.ended_at,
  r.tick_hz,
  r.dt_sec,
  r.max_steps,
  r.created_at,
  r.updated_at,
  r.seal_hash_sha256,
  r.replay_hash_sha256,
  r.hashes_match,

  coalesce(rr.readings_count, 0::bigint) as readings_count,
  rr.min_step_index,
  rr.max_step_index,
  rr.min_created_at as readings_first_at,
  rr.max_created_at as readings_last_at,

  -- nodes proof
  coalesce(nn.nodes_count, 0::bigint) as nodes_count,
  rgsr.engine_run_nodes_hash_sha256(r.run_id) as nodes_hash_sha256

from rgsr.engine_runs r
left join (
  select
    engine_run_readings.run_id,
    count(*) as readings_count,
    min(engine_run_readings.step_index) as min_step_index,
    max(engine_run_readings.step_index) as max_step_index,
    min(engine_run_readings.created_at) as min_created_at,
    max(engine_run_readings.created_at) as max_created_at
  from rgsr.engine_run_readings
  group by engine_run_readings.run_id
) rr on rr.run_id = r.run_id
left join (
  -- prefer snapshot count if exists; else live nodes
  select
    x.run_id,
    count(*) as nodes_count
  from (
    select s.run_id, s.node_id
    from rgsr.engine_run_nodes_snapshot s
    union all
    select n.run_id, n.node_id
    from rgsr.engine_run_nodes n
    where not exists (
      select 1
      from rgsr.engine_run_nodes_snapshot s2
      where s2.run_id = n.run_id
    )
  ) x
  group by x.run_id
) nn on nn.run_id = r.run_id;

comment on view rgsr.v_engine_run_attestation is
'Attestation surface for a run: includes sealing/replay fields plus readings proof and node set proof (count + hash).';

commit;
