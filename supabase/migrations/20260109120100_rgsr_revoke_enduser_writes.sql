-- RGSR: Revoke all end-user write access (authenticated / anon)
-- Canonical audit source: _handoff/_audit/rgsr/A2a_table_write_grants.tsv

begin;

-- Safety: never revoke from postgres or service_role here
-- Only end-user roles

revoke insert, update, delete on all tables in schema rgsr from authenticated;
revoke insert, update, delete on all tables in schema rgsr from anon;

commit;
