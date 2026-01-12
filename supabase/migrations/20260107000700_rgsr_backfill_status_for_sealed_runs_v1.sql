begin;

update rgsr.engine_runs
   set status     = 'sealed',
       ended_at   = coalesce(ended_at, now()),
       updated_at = now()
 where seal_hash_sha256 is not null
   and coalesce(status,'') <> 'sealed';

commit;
