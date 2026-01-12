begin;

-- RGSR RLS BASELINE (IDEMPOTENT)
-- 1) Ensure RLS enabled on all rgsr tables
-- 2) Add a RESTRICTIVE deny-all policy ONLY for tables that have RLS enabled but zero policies
--    (Postgres does not support "CREATE POLICY IF NOT EXISTS", so we guard via pg_policies)

do $$
declare r record;
begin
  for r in
    select n.nspname as sch, c.relname as tbl
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'rgsr'
      and c.relkind = 'r'
  loop
    execute format('alter table %I.%I enable row level security', r.sch, r.tbl);
  end loop;
end
$$;

-- Add deny-all policy ONLY where RLS is enabled AND there are no policies yet
do $$
declare
  r record;
  v_pol text;
begin
  for r in
    with rls_tables as (
      select n.nspname as sch, c.relname as tbl
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'rgsr'
        and c.relkind = 'r'
        and c.relrowsecurity
    ),
    policy_counts as (
      select schemaname as sch, tablename as tbl, count(*) as policy_count
      from pg_policies
      where schemaname = 'rgsr'
      group by schemaname, tablename
    )
    select rt.sch, rt.tbl
    from rls_tables rt
    left join policy_counts pc
      on pc.sch = rt.sch and pc.tbl = rt.tbl
    where coalesce(pc.policy_count, 0) = 0
  loop
    -- policy name must be <= 63 bytes
    v_pol := left('deny_all__' || r.tbl, 63);

    if not exists (
      select 1
      from pg_policies p
      where p.schemaname = r.sch
        and p.tablename  = r.tbl
        and p.policyname = v_pol
    ) then
      execute format(
        'create policy %I on %I.%I as restrictive for all to public using (false) with check (false)',
        v_pol, r.sch, r.tbl
      );
    end if;
  end loop;
end
$$;

commit;