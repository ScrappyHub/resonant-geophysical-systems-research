begin;

-- RGSR: Revoke PUBLIC writes (idempotent)
-- Goal: "public" role should never have mutation ability in rgsr.
-- Note: this does NOT touch postgres/service_role.

-- Tables
revoke insert, update, delete, truncate, references, trigger
  on all tables in schema rgsr
  from public;

-- Sequences (covers nextval/setval usage)
revoke usage, update
  on all sequences in schema rgsr
  from public;

-- Functions (keep EXECUTE off by default for public)
revoke execute
  on all functions in schema rgsr
  from public;

commit;
