begin;

create extension if not exists pgcrypto with schema extensions;

create or replace function rgsr.engine_run_hash_sha256(p_run_id uuid)
returns text
language sql
stable
as $$
  select encode(
    extensions.digest(
      convert_to(
        coalesce(
          string_agg(
            (
              (r.step_index::text) || ':' ||
              (r.node_id::text) || ':' ||
              coalesce(r.t_sim_sec::text, '') || ':' ||
              coalesce(r.readings::text, '')
            ),
            '|' order by r.step_index asc, r.node_id asc, r.reading_id asc
          ),
          ''
        ),
        'utf8'
      ),
      'sha256'
    ),
    'hex'
  )
  from rgsr.engine_run_readings r
  where r.run_id = p_run_id;
$$;

comment on function rgsr.engine_run_hash_sha256(uuid)
is 'Canonical seal hash over engine_run_readings; schema-qualifies extensions.digest to avoid search_path dependency.';

commit;
