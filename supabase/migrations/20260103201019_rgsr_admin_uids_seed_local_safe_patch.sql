-- 20260103201019_rgsr_admin_uids_seed_local_safe_patch.sql
-- Local + shadow safe: insert only UIDs that actually exist in auth.users.

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
