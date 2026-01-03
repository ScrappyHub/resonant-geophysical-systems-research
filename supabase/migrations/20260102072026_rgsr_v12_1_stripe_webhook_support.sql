-- ============================================================
-- RGSR v12.1 — STRIPE WEBHOOK SUPPORT (NO PII)
-- - Adds canonical linkage RPCs (admin only) for mapping Stripe customer -> owner
-- - Adds user bootstrap RPC for billing_account row (no processor ids needed)
-- - No auth.* mutations, no PII
-- ============================================================
begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 1) User bootstrap: create billing_account row (no customer id yet)
-- ------------------------------------------------------------
create or replace function rgsr.bootstrap_billing_account(
  p_processor text default 'stripe'
) returns jsonb
language plpgsql
security invoker
as $fn$
declare
  v_owner uuid;
  v_proc text;
  v_ba_id uuid;
begin
  v_owner := rgsr.actor_uid();
  if v_owner is null then
    raise exception 'AUTH_REQUIRED' using errcode='28000';
  end if;

  v_proc := coalesce(nullif(btrim(p_processor),''), 'stripe');

  insert into rgsr.billing_accounts(owner_uid, processor)
  values (v_owner, v_proc)
  on conflict (owner_uid, processor) do update
    set updated_at = now()
  returning billing_account_id into v_ba_id;

  return jsonb_build_object('ok', true, 'billing_account_id', v_ba_id, 'owner_uid', v_owner, 'processor', v_proc);
end
$fn$;

-- ------------------------------------------------------------
-- 2) Admin linkage: set/patch Stripe customer id for an owner
--    (used when Stripe customer gets created on checkout)
-- ------------------------------------------------------------
create or replace function rgsr.admin_link_processor_customer(
  p_owner_uid uuid,
  p_processor text,
  p_processor_customer_id text
) returns jsonb
language plpgsql
security definer
as $fn$
declare
  v_proc text;
  v_ba_id uuid;
begin
  if not rgsr.can_write() then
    raise exception 'ADMIN_REQUIRED' using errcode='28000';
  end if;

  if p_owner_uid is null then
    raise exception 'OWNER_UID_REQUIRED' using errcode='22023';
  end if;

  v_proc := coalesce(nullif(btrim(p_processor),''), 'stripe');

  insert into rgsr.billing_accounts(owner_uid, processor, processor_customer_id, updated_at)
  values (p_owner_uid, v_proc, nullif(btrim(p_processor_customer_id),''), now())
  on conflict (owner_uid, processor) do update
    set processor_customer_id = coalesce(nullif(btrim(excluded.processor_customer_id),''), rgsr.billing_accounts.processor_customer_id),
        updated_at = now()
  returning billing_account_id into v_ba_id;

  return jsonb_build_object('ok', true, 'billing_account_id', v_ba_id, 'owner_uid', p_owner_uid, 'processor', v_proc);
end
$fn$;

-- ------------------------------------------------------------
-- 3) Policy: allow authenticated users to call bootstrap (RPC)
-- ------------------------------------------------------------
grant execute on function rgsr.bootstrap_billing_account(text) to authenticated;
grant execute on function rgsr.admin_link_processor_customer(uuid,text,text) to service_role;

commit;
