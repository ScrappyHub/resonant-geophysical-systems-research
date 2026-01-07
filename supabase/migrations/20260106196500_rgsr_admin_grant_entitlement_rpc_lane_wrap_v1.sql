begin;

-- CANONICAL NOOP: superseded.
-- This migration previously contained invalid PL/pgSQL ("ensure") and broke resets.
-- Canonical path is 97050 (RPC) + 97100 (trigger honors lane).

do $$
begin
  raise notice 'CANONICAL NOOP 20260106196500: superseded by 97050/97100';
end
$$;

commit;