-- ============================================================
-- RGSR v12.0 — BILLING / INVOICES (NO PII, RLS FORCED)
-- - Stores ONLY: auth uid + processor ids + amounts/statuses/timestamps
-- - Idempotent webhook event table
-- - Invoices + line items + payments + entitlements
-- - Admin moderation/deletion via rgsr.can_write()
-- ============================================================

begin;

create schema if not exists rgsr;

-- ------------------------------------------------------------
-- 0) Guard rails: NO direct auth schema edits
-- ------------------------------------------------------------
-- This migration intentionally does NOT alter auth.* tables.

-- ------------------------------------------------------------
-- 1) Billing account mapping (per auth user)
--    No email/phone; processor ids are not PII by themselves.
-- ------------------------------------------------------------
create table if not exists rgsr.billing_accounts (
  billing_account_id uuid primary key default gen_random_uuid(),
  owner_uid uuid not null references auth.users(id) on delete restrict,

  -- processor identifiers (Stripe-friendly)
  processor text not null default 'stripe',
  processor_customer_id text null,     -- e.g. cus_...
  processor_account_id  text null,     -- connect acct_... if ever needed

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint billing_accounts_owner_unique unique (owner_uid, processor),
  constraint billing_accounts_processor_chk check (processor in ('stripe','manual','other'))
);

create index if not exists ix_billing_accounts_owner on rgsr.billing_accounts(owner_uid);

-- ------------------------------------------------------------
-- 2) Webhook event sink (idempotency + audit)
-- ------------------------------------------------------------
create table if not exists rgsr.payment_events (
  event_id uuid primary key default gen_random_uuid(),
  processor text not null default 'stripe',
  processor_event_id text not null,   -- Stripe: evt_...
  event_type text not null,           -- Stripe type
  received_at timestamptz not null default now(),
  payload jsonb not null default '{}'::jsonb,

  -- optional linkage
  owner_uid uuid null references auth.users(id) on delete set null,
  billing_account_id uuid null references rgsr.billing_accounts(billing_account_id) on delete set null,

  constraint payment_events_unique unique (processor, processor_event_id)
);

create index if not exists ix_payment_events_type_time on rgsr.payment_events(event_type, received_at desc);
create index if not exists ix_payment_events_owner on rgsr.payment_events(owner_uid);

-- ------------------------------------------------------------
-- 3) Invoices
-- ------------------------------------------------------------
create table if not exists rgsr.invoices (
  invoice_id uuid primary key default gen_random_uuid(),
  billing_account_id uuid not null references rgsr.billing_accounts(billing_account_id) on delete restrict,
  owner_uid uuid not null references auth.users(id) on delete restrict,

  processor text not null default 'stripe',
  processor_invoice_id text null,     -- Stripe: in_...
  processor_subscription_id text null, -- Stripe: sub_... (optional)
  processor_payment_intent_id text null, -- pi_... (optional)

  status text not null default 'draft', -- draft/open/paid/void/uncollectible
  currency text not null default 'usd',
  amount_subtotal bigint not null default 0,
  amount_total bigint not null default 0,
  amount_due bigint not null default 0,

  issued_at timestamptz null,
  due_at timestamptz null,
  paid_at timestamptz null,

  period_start timestamptz null,
  period_end timestamptz null,

  hosted_invoice_url text null,
  invoice_pdf_url text null,

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint invoices_status_chk check (status in ('draft','open','paid','void','uncollectible')),
  constraint invoices_currency_chk check (length(currency) between 3 and 6)
);

create index if not exists ix_invoices_owner_time on rgsr.invoices(owner_uid, created_at desc);
create index if not exists ix_invoices_processor_invoice on rgsr.invoices(processor, processor_invoice_id);

-- ------------------------------------------------------------
-- 4) Invoice line items
-- ------------------------------------------------------------
create table if not exists rgsr.invoice_line_items (
  line_item_id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references rgsr.invoices(invoice_id) on delete cascade,

  description text not null,
  quantity bigint not null default 1,
  unit_amount bigint not null default 0,
  amount_total bigint not null default 0,

  processor_price_id text null,      -- Stripe: price_...
  processor_product_id text null,    -- Stripe: prod_...

  tags text[] not null default '{}'::text[],
  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint invoice_line_qty_chk check (quantity >= 1),
  constraint invoice_line_amounts_chk check (unit_amount >= 0 and amount_total >= 0)
);

create index if not exists ix_invoice_line_items_invoice on rgsr.invoice_line_items(invoice_id);

-- ------------------------------------------------------------
-- 5) Payments (charges / payment intents) — ledger-ish
-- ------------------------------------------------------------
create table if not exists rgsr.payments (
  payment_id uuid primary key default gen_random_uuid(),
  billing_account_id uuid not null references rgsr.billing_accounts(billing_account_id) on delete restrict,
  owner_uid uuid not null references auth.users(id) on delete restrict,

  processor text not null default 'stripe',
  processor_payment_intent_id text null, -- pi_...
  processor_charge_id text null,         -- ch_...
  processor_invoice_id text null,        -- in_...

  status text not null default 'pending', -- pending/succeeded/failed/refunded/canceled
  currency text not null default 'usd',
  amount bigint not null default 0,

  succeeded_at timestamptz null,
  failed_at timestamptz null,
  refunded_at timestamptz null,

  metadata jsonb not null default '{}'::jsonb,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint payments_status_chk check (status in ('pending','succeeded','failed','refunded','canceled'))
);

create index if not exists ix_payments_owner_time on rgsr.payments(owner_uid, created_at desc);
create index if not exists ix_payments_processor_pi on rgsr.payments(processor, processor_payment_intent_id);

-- ------------------------------------------------------------
-- 6) Entitlements / plan access (feature flags backend)
--    This is where your 2D/3D engine gates hook in canonically.
-- ------------------------------------------------------------
create table if not exists rgsr.entitlements (
  entitlement_id uuid primary key default gen_random_uuid(),
  owner_uid uuid not null references auth.users(id) on delete restrict,

  entitlement_key text not null,  -- e.g. 'ENGINE_3D_PRO', 'EXPORTS', 'CLOUD_STORAGE_GB'
  entitlement_value jsonb not null default '{}'::jsonb,

  source text not null default 'billing', -- billing/admin/grant
  active boolean not null default true,

  starts_at timestamptz not null default now(),
  ends_at timestamptz null,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint entitlements_source_chk check (source in ('billing','admin','grant')),
  constraint entitlements_key_chk check (length(entitlement_key) > 2),
  constraint entitlements_unique_active unique (owner_uid, entitlement_key, active)
);

create index if not exists ix_entitlements_owner_active on rgsr.entitlements(owner_uid, active);

-- ------------------------------------------------------------
-- 7) Helper RPCs (read-only)
-- ------------------------------------------------------------
create or replace function rgsr.get_my_invoices()
returns jsonb
language sql
stable
as $fn$
  select jsonb_build_object(
    'invoices', coalesce(jsonb_agg(to_jsonb(i) order by i.created_at desc), '[]'::jsonb)
  )
  from rgsr.invoices i
  where i.owner_uid = rgsr.actor_uid();
$fn$;

create or replace function rgsr.get_my_entitlements()
returns jsonb
language sql
stable
as $fn$
  select jsonb_build_object(
    'entitlements', coalesce(jsonb_agg(to_jsonb(e) order by e.entitlement_key), '[]'::jsonb)
  )
  from rgsr.entitlements e
  where e.owner_uid = rgsr.actor_uid()
    and e.active = true
    and (e.ends_at is null or e.ends_at > now());
$fn$;

-- ------------------------------------------------------------
-- 8) RLS enable + FORCE (everything billing)
-- ------------------------------------------------------------
alter table rgsr.billing_accounts enable row level security;
alter table rgsr.payment_events enable row level security;
alter table rgsr.invoices enable row level security;
alter table rgsr.invoice_line_items enable row level security;
alter table rgsr.payments enable row level security;
alter table rgsr.entitlements enable row level security;

alter table rgsr.billing_accounts force row level security;
alter table rgsr.payment_events force row level security;
alter table rgsr.invoices force row level security;
alter table rgsr.invoice_line_items force row level security;
alter table rgsr.payments force row level security;
alter table rgsr.entitlements force row level security;

-- ------------------------------------------------------------
-- 9) Drop non-canonical policies (avoid union leakage)
-- ------------------------------------------------------------
do $do$
declare p record;
begin
  for p in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname='rgsr'
      and tablename in ('billing_accounts','payment_events','invoices','invoice_line_items','payments','entitlements')
  loop
    execute format('drop policy if exists %I on %I.%I', p.policyname, p.schemaname, p.tablename);
  end loop;
end
$do$;

-- ------------------------------------------------------------
-- 10) Canonical policies
--     - Users: read own
--     - Inserts: via server/webhook/admin only (rgsr.can_write()) except limited self bootstrap
--     - Admin: full control
-- ------------------------------------------------------------

-- billing_accounts
create policy billing_accounts_read on rgsr.billing_accounts
for select to authenticated
using (owner_uid = rgsr.actor_uid());

-- allow authenticated user to bootstrap their own billing account row (no processor ids required yet)
create policy billing_accounts_bootstrap on rgsr.billing_accounts
for insert to authenticated
with check (
  owner_uid = rgsr.actor_uid()
  and processor in ('stripe','manual','other')
);

create policy billing_accounts_admin on rgsr.billing_accounts
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- payment_events (webhook sink) — only admin/service flows write; users can’t see raw payloads
create policy payment_events_admin on rgsr.payment_events
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- invoices
create policy invoices_read_own on rgsr.invoices
for select to authenticated
using (owner_uid = rgsr.actor_uid());

create policy invoices_admin on rgsr.invoices
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- invoice_line_items inherits invoice visibility
create policy invoice_lines_read on rgsr.invoice_line_items
for select to authenticated
using (
  exists (
    select 1 from rgsr.invoices i
    where i.invoice_id = invoice_line_items.invoice_id
      and i.owner_uid = rgsr.actor_uid()
  )
);

create policy invoice_lines_admin on rgsr.invoice_line_items
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- payments
create policy payments_read_own on rgsr.payments
for select to authenticated
using (owner_uid = rgsr.actor_uid());

create policy payments_admin on rgsr.payments
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- entitlements
create policy entitlements_read_own on rgsr.entitlements
for select to authenticated
using (owner_uid = rgsr.actor_uid());

create policy entitlements_admin on rgsr.entitlements
for all to authenticated
using (rgsr.can_write())
with check (rgsr.can_write());

-- ------------------------------------------------------------
-- 11) Grants (minimal; RLS is FORCED gate)
-- ------------------------------------------------------------
do $do$
begin
  revoke all on schema rgsr from public;
  grant usage on schema rgsr to authenticated;
  grant usage on schema rgsr to service_role;
end
$do$;

commit;

-- ============================================================
-- Verification (manual):
-- select rgsr.get_my_invoices();
-- select rgsr.get_my_entitlements();
-- ============================================================
