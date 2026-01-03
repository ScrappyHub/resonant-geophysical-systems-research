-- ============================================================
-- RGSR v12.1 — BILLING WEBHOOK INGEST (NO PII)
-- - Idempotent event ingest
-- - Upsert invoices/payments/billing accounts
-- - Entitlement writes for backend-only feature gates
-- - Service/admin only ingestion; users read own via RLS
-- ============================================================

begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 1) Minimal helper: now_utc
-- ------------------------------------------------------------
create or replace function rgsr.now_utc()
returns timestamptz
language sql
stable
as $fn$
  select now();
$fn$;

-- ------------------------------------------------------------
-- 2) Billing account upsert (owner + processor)
-- ------------------------------------------------------------
create or replace function rgsr.upsert_billing_account_for_owner(
  p_owner_uid uuid,
  p_processor text,
  p_processor_customer_id text default null,
  p_processor_account_id text default null
) returns uuid
language plpgsql
security definer
as $fn$
declare
  v_id uuid;
begin
  if p_owner_uid is null then
    raise exception 'OWNER_REQUIRED' using errcode='22023';
  end if;

  insert into rgsr.billing_accounts(owner_uid, processor, processor_customer_id, processor_account_id, created_at, updated_at)
  values (p_owner_uid, coalesce(p_processor,'stripe'), p_processor_customer_id, p_processor_account_id, now(), now())
  on conflict (owner_uid, processor) do update
    set processor_customer_id = coalesce(excluded.processor_customer_id, rgsr.billing_accounts.processor_customer_id),
        processor_account_id  = coalesce(excluded.processor_account_id,  rgsr.billing_accounts.processor_account_id),
        updated_at = now()
  returning billing_account_id into v_id;

  return v_id;
end
$fn$;

-- ------------------------------------------------------------
-- 3) Invoice upsert from an event payload
--    We store minimal extracted values; keep raw payload already in payment_events.
-- ------------------------------------------------------------
create or replace function rgsr.upsert_invoice_from_event(
  p_owner_uid uuid,
  p_billing_account_id uuid,
  p_processor text,
  p_invoice jsonb
) returns uuid
language plpgsql
security definer
as $fn$
declare
  v_invoice_id uuid;
  v_proc_invoice text;
  v_status text;
  v_currency text;
  v_subtotal bigint;
  v_total bigint;
  v_due bigint;
  v_hosted text;
  v_pdf text;
  v_paid_at timestamptz;
  v_issued_at timestamptz;
  v_due_at timestamptz;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_sub_id text;
  v_pi_id text;
begin
  if p_owner_uid is null or p_billing_account_id is null then
    raise exception 'OWNER_OR_ACCOUNT_REQUIRED' using errcode='22023';
  end if;

  v_proc_invoice := nullif(p_invoice->>'id','');
  v_status := coalesce(nullif(p_invoice->>'status',''), 'draft');
  v_currency := coalesce(nullif(p_invoice->>'currency',''), 'usd');

  v_subtotal := coalesce((p_invoice->>'subtotal')::bigint, 0);
  v_total    := coalesce((p_invoice->>'total')::bigint, 0);
  v_due      := coalesce((p_invoice->>'amount_due')::bigint, 0);

  v_hosted := nullif(p_invoice->>'hosted_invoice_url','');
  v_pdf    := nullif(p_invoice->>'invoice_pdf','');

  -- Stripe times are unix seconds; tolerate nulls
  if (p_invoice ? 'status_transitions') then
    if ((p_invoice->'status_transitions') ? 'paid_at') then
      v_paid_at := to_timestamp(coalesce((p_invoice->'status_transitions'->>'paid_at')::bigint,0));
      if (v_paid_at = to_timestamp(0)) then v_paid_at := null; end if;
    end if;
  end if;

  if (p_invoice ? 'created') then
    v_issued_at := to_timestamp(coalesce((p_invoice->>'created')::bigint,0));
    if (v_issued_at = to_timestamp(0)) then v_issued_at := null; end if;
  end if;

  if (p_invoice ? 'due_date') then
    v_due_at := to_timestamp(coalesce((p_invoice->>'due_date')::bigint,0));
    if (v_due_at = to_timestamp(0)) then v_due_at := null; end if;
  end if;

  v_sub_id := nullif(p_invoice->>'subscription','');
  v_pi_id  := nullif(p_invoice->>'payment_intent','');

  insert into rgsr.invoices(
    billing_account_id, owner_uid,
    processor, processor_invoice_id, processor_subscription_id, processor_payment_intent_id,
    status, currency, amount_subtotal, amount_total, amount_due,
    issued_at, due_at, paid_at,
    hosted_invoice_url, invoice_pdf_url,
    period_start, period_end,
    metadata, created_at, updated_at
  ) values (
    p_billing_account_id, p_owner_uid,
    coalesce(p_processor,'stripe'), v_proc_invoice, v_sub_id, v_pi_id,
    v_status, v_currency, v_subtotal, v_total, v_due,
    v_issued_at, v_due_at, v_paid_at,
    v_hosted, v_pdf,
    v_period_start, v_period_end,
    jsonb_build_object('source','event_upsert'),
    now(), now()
  )
  on conflict (processor, processor_invoice_id) do update
    set status = excluded.status,
        currency = excluded.currency,
        amount_subtotal = excluded.amount_subtotal,
        amount_total = excluded.amount_total,
        amount_due = excluded.amount_due,
        issued_at = excluded.issued_at,
        due_at = excluded.due_at,
        paid_at = excluded.paid_at,
        hosted_invoice_url = excluded.hosted_invoice_url,
        invoice_pdf_url = excluded.invoice_pdf_url,
        processor_subscription_id = coalesce(excluded.processor_subscription_id, rgsr.invoices.processor_subscription_id),
        processor_payment_intent_id = coalesce(excluded.processor_payment_intent_id, rgsr.invoices.processor_payment_intent_id),
        updated_at = now()
  returning invoice_id into v_invoice_id;

  return v_invoice_id;
end
$fn$;

-- ------------------------------------------------------------
-- 4) Payment upsert from an event payload (payment_intent / charge)
-- ------------------------------------------------------------
create or replace function rgsr.upsert_payment_from_event(
  p_owner_uid uuid,
  p_billing_account_id uuid,
  p_processor text,
  p_payment jsonb
) returns uuid
language plpgsql
security definer
as $fn$
declare
  v_payment_id uuid;
  v_pi text;
  v_ch text;
  v_inv text;
  v_status text;
  v_currency text;
  v_amount bigint;
  v_succeeded_at timestamptz;
begin
  if p_owner_uid is null or p_billing_account_id is null then
    raise exception 'OWNER_OR_ACCOUNT_REQUIRED' using errcode='22023';
  end if;

  v_pi := nullif(p_payment->>'id',''); -- if payload is a payment_intent
  v_status := coalesce(nullif(p_payment->>'status',''),'pending');
  v_currency := coalesce(nullif(p_payment->>'currency',''),'usd');

  if (p_payment ? 'amount') then
    v_amount := coalesce((p_payment->>'amount')::bigint,0);
  else
    v_amount := coalesce((p_payment->>'amount_received')::bigint,0);
  end if;

  -- optional links
  v_inv := nullif(p_payment->>'invoice','');

  if v_status = 'succeeded' then
    v_succeeded_at := now();
  end if;

  insert into rgsr.payments(
    billing_account_id, owner_uid,
    processor, processor_payment_intent_id, processor_charge_id, processor_invoice_id,
    status, currency, amount,
    succeeded_at,
    metadata, created_at, updated_at
  ) values (
    p_billing_account_id, p_owner_uid,
    coalesce(p_processor,'stripe'), v_pi, v_ch, v_inv,
    v_status, v_currency, coalesce(v_amount,0),
    v_succeeded_at,
    jsonb_build_object('source','event_upsert'),
    now(), now()
  )
  on conflict (processor, processor_payment_intent_id) do update
    set status = excluded.status,
        currency = excluded.currency,
        amount = excluded.amount,
        succeeded_at = coalesce(excluded.succeeded_at, rgsr.payments.succeeded_at),
        updated_at = now()
  returning payment_id into v_payment_id;

  return v_payment_id;
end
$fn$;

-- ------------------------------------------------------------
-- 5) Entitlements: set/unset keys (backend gating)
-- ------------------------------------------------------------
create or replace function rgsr.set_entitlement(
  p_owner_uid uuid,
  p_key text,
  p_value jsonb default '{}'::jsonb,
  p_active boolean default true,
  p_source text default 'billing',
  p_starts_at timestamptz default now(),
  p_ends_at timestamptz default null
) returns uuid
language plpgsql
security definer
as $fn$
declare
  v_id uuid;
begin
  if p_owner_uid is null then
    raise exception 'OWNER_REQUIRED' using errcode='22023';
  end if;
  if p_key is null or length(btrim(p_key)) < 3 then
    raise exception 'KEY_REQUIRED' using errcode='22023';
  end if;

  insert into rgsr.entitlements(
    owner_uid, entitlement_key, entitlement_value,
    source, active, starts_at, ends_at,
    created_at, updated_at
  ) values (
    p_owner_uid, btrim(p_key), coalesce(p_value,'{}'::jsonb),
    coalesce(p_source,'billing'), coalesce(p_active,true),
    coalesce(p_starts_at, now()), p_ends_at,
    now(), now()
  )
  on conflict (owner_uid, entitlement_key, active) do update
    set entitlement_value = excluded.entitlement_value,
        source = excluded.source,
        starts_at = excluded.starts_at,
        ends_at = excluded.ends_at,
        updated_at = now()
  returning entitlement_id into v_id;

  return v_id;
end
$fn$;

-- ------------------------------------------------------------
-- 6) Apply entitlements from event (pluggable)
--    For now: if invoice paid => grant base keys in a minimal way.
--    You can later map Stripe price/product ids to entitlement bundles.
-- ------------------------------------------------------------
create or replace function rgsr.apply_entitlements_from_event(
  p_owner_uid uuid,
  p_event_type text,
  p_object jsonb
) returns void
language plpgsql
security definer
as $fn$
declare
  v_status text;
begin
  if p_owner_uid is null then return; end if;

  v_status := nullif(p_object->>'status','');

  -- Example: invoice.payment_succeeded => grant base runtime
  if p_event_type in ('invoice.payment_succeeded','checkout.session.completed') then
    perform rgsr.set_entitlement(p_owner_uid, 'BILLING_ACTIVE', jsonb_build_object('ok', true), true, 'billing', now(), null);
    -- conservative defaults (you can replace with plan-mapped bundles later)
    perform rgsr.set_entitlement(p_owner_uid, 'ENGINE_2D', jsonb_build_object('tier','base'), true, 'billing', now(), null);
    perform rgsr.set_entitlement(p_owner_uid, 'ENGINE_3D', jsonb_build_object('tier','base'), true, 'billing', now(), null);
  end if;

  -- Example: invoice.voided / customer.subscription.deleted => deactivate via ends_at
  if p_event_type in ('customer.subscription.deleted','invoice.voided') then
    perform rgsr.set_entitlement(p_owner_uid, 'BILLING_ACTIVE', jsonb_build_object('ok', false), true, 'billing', now(), now());
  end if;
end
$fn$;

-- ------------------------------------------------------------
-- 7) Canonical ingestion RPC (service/admin only)
-- ------------------------------------------------------------
create or replace function rgsr.ingest_payment_event(
  p_processor text,
  p_processor_event_id text,
  p_event_type text,
  p_payload jsonb,
  p_owner_uid uuid default null,             -- optional if you already resolved it
  p_processor_customer_id text default null  -- optional helper for mapping
) returns jsonb
language plpgsql
security definer
as $fn$
declare
  v_proc text;
  v_event_id uuid;
  v_owner uuid;
  v_billing_account_id uuid;
  v_object jsonb;
  v_obj_type text;
  v_invoice_id uuid;
  v_payment_id uuid;
begin
  -- hard gate: only admin/service flows
  if not rgsr.can_write() then
    raise exception 'ADMIN_REQUIRED' using errcode='28000';
  end if;

  v_proc := coalesce(nullif(p_processor,''),'stripe');

  if p_processor_event_id is null or length(btrim(p_processor_event_id)) < 6 then
    raise exception 'EVENT_ID_REQUIRED' using errcode='22023';
  end if;
  if p_event_type is null or length(btrim(p_event_type)) < 3 then
    raise exception 'EVENT_TYPE_REQUIRED' using errcode='22023';
  end if;

  v_owner := p_owner_uid;

  -- Stripe convention: payload.data.object
  v_object := coalesce(p_payload #> '{data,object}', '{}'::jsonb);

  -- idempotent insert into payment_events
  insert into rgsr.payment_events(processor, processor_event_id, event_type, payload, owner_uid, received_at)
  values (v_proc, btrim(p_processor_event_id), btrim(p_event_type), coalesce(p_payload,'{}'::jsonb), v_owner, now())
  on conflict (processor, processor_event_id) do update
    set payload = excluded.payload,
        event_type = excluded.event_type,
        owner_uid = coalesce(excluded.owner_uid, rgsr.payment_events.owner_uid)
  returning event_id, owner_uid into v_event_id, v_owner;

  -- If owner still unknown but caller provided customer id, we can map via billing_accounts
  if v_owner is null and p_processor_customer_id is not null then
    select owner_uid into v_owner
    from rgsr.billing_accounts
    where processor = v_proc and processor_customer_id = p_processor_customer_id
    limit 1;
  end if;

  -- If we have an owner, ensure billing_account exists
  if v_owner is not null then
    v_billing_account_id := rgsr.upsert_billing_account_for_owner(v_owner, v_proc, p_processor_customer_id, null);
    update rgsr.payment_events
      set owner_uid = v_owner, billing_account_id = v_billing_account_id
      where event_id = v_event_id;
  end if;

  -- Upsert invoice/payment depending on event object type
  v_obj_type := nullif(v_object->>'object','');

  if v_owner is not null and v_billing_account_id is not null then
    if v_obj_type = 'invoice' then
      v_invoice_id := rgsr.upsert_invoice_from_event(v_owner, v_billing_account_id, v_proc, v_object);
      perform rgsr.apply_entitlements_from_event(v_owner, btrim(p_event_type), v_object);
    elsif v_obj_type in ('payment_intent','charge') then
      v_payment_id := rgsr.upsert_payment_from_event(v_owner, v_billing_account_id, v_proc, v_object);
      perform rgsr.apply_entitlements_from_event(v_owner, btrim(p_event_type), v_object);
    else
      -- unknown object type: still stored raw in payment_events; no-op on derived tables
      null;
    end if;
  end if;

  return jsonb_build_object(
    'ok', true,
    'event_id', v_event_id,
    'owner_uid', v_owner,
    'billing_account_id', v_billing_account_id,
    'invoice_id', v_invoice_id,
    'payment_id', v_payment_id
  );
end
$fn$;

-- ------------------------------------------------------------
-- 8) Lock down execution: only service_role should execute ingest
--    (admins can do via can_write() but keep execution narrow)
-- ------------------------------------------------------------
revoke all on function rgsr.ingest_payment_event(text,text,text,jsonb,uuid,text) from public;
revoke all on function rgsr.ingest_payment_event(text,text,text,jsonb,uuid,text) from anon;
revoke all on function rgsr.ingest_payment_event(text,text,text,jsonb,uuid,text) from authenticated;
grant execute on function rgsr.ingest_payment_event(text,text,text,jsonb,uuid,text) to service_role;

commit;

-- ============================================================
-- Verification (manual; requires service/admin context):
-- select rgsr.ingest_payment_event('stripe','evt_test_123','invoice.payment_succeeded',
--   '{"data":{"object":{"object":"invoice","id":"in_test_1","status":"paid","currency":"usd","subtotal":1000,"total":1000,"amount_due":0,"created":1700000000}}}'::jsonb,
--   '<OWNER_UID>'::uuid,
--   'cus_test_1'
-- );
-- ============================================================
