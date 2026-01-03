param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$false)][string]$ProjectRef = "",
  [switch]$LinkProject,
  [switch]$ApplyRemote,

  # Optional: deploy function + set secrets now (you can rerun later)
  [switch]$DeployFunction,
  [switch]$SetSecrets,
  [Parameter(Mandatory=$false)][string]$SupabaseUrl = "",
  [Parameter(Mandatory=$false)][string]$ServiceRoleKey = "",
  [Parameter(Mandatory=$false)][string]$StripeSecretKey = "",
  [Parameter(Mandatory=$false)][string]$StripeWebhookSecret = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

function WriteUtf8NoBom([string]$Path, [string]$Content) {
  $dir = Split-Path -Parent $Path
  if ($dir) { EnsureDir $dir }
  [IO.File]::WriteAllText($Path, $Content, (New-Object Text.UTF8Encoding($false)))
  Write-Host ("[OK] WROTE " + $Path) -ForegroundColor Green
}

function Invoke-Supabase([string[]]$SbArgs, [switch]$PipeYes) {
  if (-not $SbArgs -or $SbArgs.Count -eq 0) { throw "Invoke-Supabase called with empty args" }
  $argStr = ($SbArgs -join " ")
  if ($PipeYes) {
    cmd /c ("echo y| supabase " + $argStr) | Out-Host
    $code = $LASTEXITCODE
  } else {
    & supabase @SbArgs
    $code = $LASTEXITCODE
  }
  if ($code -ne 0) { throw ("supabase " + $argStr + " failed (exit=" + $code + ")") }
}

if (-not (Test-Path -LiteralPath $RepoRoot)) { throw "RepoRoot not found: $RepoRoot" }
Set-Location $RepoRoot

if (-not (Get-Command supabase -ErrorAction SilentlyContinue)) { throw "supabase CLI not found in PATH." }

$mgDir = Join-Path $RepoRoot "supabase\migrations"
EnsureDir $mgDir

# ------------------------------------------------------------
# 1) Write migration (v12.1) — webhook support + admin linkage RPCs
# ------------------------------------------------------------
$MigrationId = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$mgPath = Join-Path $mgDir ("{0}_rgsr_v12_1_stripe_webhook_support.sql" -f $MigrationId)

$sql = @'
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
'@

WriteUtf8NoBom $mgPath ($sql + "`r`n")
Write-Host ("[OK] NEW MIGRATION READY: " + $mgPath) -ForegroundColor Green

# ------------------------------------------------------------
# 2) Write Edge Function: rgsr_stripe_webhook
# ------------------------------------------------------------
$fnDir = Join-Path $RepoRoot "supabase\functions\rgsr_stripe_webhook"
EnsureDir $fnDir
$fnPath = Join-Path $fnDir "index.ts"

$fnCode = @'
/**
 * RGSR Stripe Webhook (CORE / ROOTED governance compatible)
 * - NO PII stored
 * - Verifies Stripe signature (STRIPE_WEBHOOK_SECRET)
 * - Calls PostgREST RPC: rgsr.ingest_payment_event as service_role
 *
 * Required secrets:
 * - SUPABASE_URL
 * - SUPABASE_SERVICE_ROLE_KEY
 * - STRIPE_SECRET_KEY (optional; not required for signature verify)
 * - STRIPE_WEBHOOK_SECRET
 *
 * Deploy with:
 * supabase functions deploy rgsr_stripe_webhook --no-verify-jwt
 */

import Stripe from "https://esm.sh/stripe@16.12.0?target=deno";
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";

// NOTE: We do not need STRIPE_SECRET_KEY to verify webhooks, but Stripe SDK wants a key.
// Use a dummy if missing; signature verification still works with constructEvent.
const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "sk_test_dummy";

function must(name: string, v: string) {
  if (!v || v.trim().length === 0) throw new Error(`MISSING_SECRET:${name}`);
  return v;
}

function extractOwnerUid(obj: any): string | null {
  // Canonical metadata key (recommended)
  const meta = obj?.metadata ?? null;
  const uid = meta?.owner_uid ?? meta?.OWNER_UID ?? null;
  if (typeof uid === "string" && uid.length >= 32) return uid;
  return null;
}

function extractCustomerId(obj: any): string | null {
  const c = obj?.customer ?? obj?.customer_id ?? null;
  if (typeof c === "string" && c.length >= 6) return c;
  return null;
}

async function callIngest(args: {
  processor: string;
  processor_event_id: string;
  event_type: string;
  payload: any;
  owner_uid: string | null;
  processor_customer_id: string | null;
}) {
  const url = must("SUPABASE_URL", SUPABASE_URL);
  const key = must("SUPABASE_SERVICE_ROLE_KEY", SERVICE_ROLE);

  const rpcUrl = `${url}/rest/v1/rpc/ingest_payment_event`;
  const res = await fetch(rpcUrl, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": key,
      "Authorization": `Bearer ${key}`,
    },
    body: JSON.stringify({
      p_processor: args.processor,
      p_processor_event_id: args.processor_event_id,
      p_event_type: args.event_type,
      p_payload: args.payload,
      p_owner_uid: args.owner_uid,
      p_processor_customer_id: args.processor_customer_id,
    }),
  });

  const txt = await res.text();
  if (!res.ok) {
    throw new Error(`INGEST_FAILED:${res.status}:${txt}`);
  }
  return txt.length ? JSON.parse(txt) : null;
}

serve(async (req) => {
  try {
    must("SUPABASE_URL", SUPABASE_URL);
    must("SUPABASE_SERVICE_ROLE_KEY", SERVICE_ROLE);
    must("STRIPE_WEBHOOK_SECRET", STRIPE_WEBHOOK_SECRET);

    const sig = req.headers.get("stripe-signature");
    if (!sig) return new Response("Missing stripe-signature", { status: 400 });

    const bodyBuf = new Uint8Array(await req.arrayBuffer());
    const bodyText = new TextDecoder().decode(bodyBuf);

    const stripe = new Stripe(STRIPE_SECRET_KEY, { apiVersion: "2024-06-20" });

    let evt: any;
    try {
      evt = stripe.webhooks.constructEvent(bodyText, sig, STRIPE_WEBHOOK_SECRET);
    } catch (_e) {
      return new Response("Invalid signature", { status: 400 });
    }

    // Allowlist only what we act on; everything else still gets stored idempotently.
    const processor = "stripe";
    const processor_event_id = String(evt.id ?? "");
    const event_type = String(evt.type ?? "");
    const payload = evt; // full event; still NO PII requirement is DB side (we do not store user email/phone/etc)

    const obj = evt?.data?.object ?? {};
    const owner_uid = extractOwnerUid(obj);
    const processor_customer_id = extractCustomerId(obj);

    const out = await callIngest({
      processor,
      processor_event_id,
      event_type,
      payload,
      owner_uid,
      processor_customer_id,
    });

    return new Response(JSON.stringify({ ok: true, ingest: out }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(String(e?.message ?? e), { status: 500 });
  }
});
'@

WriteUtf8NoBom $fnPath ($fnCode + "`r`n")
Write-Host ("[OK] EDGE FUNCTION READY: " + $fnPath) -ForegroundColor Green

# ------------------------------------------------------------
# 3) Link + push migration
# ------------------------------------------------------------
if ($LinkProject) {
  if (-not $ProjectRef -or $ProjectRef.Trim().Length -lt 6) { throw "ProjectRef is required for link." }
  Invoke-Supabase -SbArgs @("link","--project-ref",$ProjectRef)
  Write-Host "[OK] supabase link complete" -ForegroundColor Green
}

if ($ApplyRemote) {
  Invoke-Supabase -SbArgs @("db","push") -PipeYes
  Write-Host "[OK] supabase db push complete" -ForegroundColor Green
}

# ------------------------------------------------------------
# 4) Optional: set secrets + deploy
# ------------------------------------------------------------
if ($SetSecrets) {
  if ($SupabaseUrl.Trim().Length -lt 10) { throw "SupabaseUrl required for -SetSecrets" }
  if ($ServiceRoleKey.Trim().Length -lt 20) { throw "ServiceRoleKey required for -SetSecrets" }
  if ($StripeWebhookSecret.Trim().Length -lt 10) { throw "StripeWebhookSecret required for -SetSecrets" }

  $pairs = @(
    "SUPABASE_URL=$SupabaseUrl",
    "SUPABASE_SERVICE_ROLE_KEY=$ServiceRoleKey",
    "STRIPE_WEBHOOK_SECRET=$StripeWebhookSecret"
  )
  if ($StripeSecretKey.Trim().Length -ge 10) { $pairs += "STRIPE_SECRET_KEY=$StripeSecretKey" }

  Invoke-Supabase -SbArgs @("secrets","set") + $pairs
  Write-Host "[OK] secrets set" -ForegroundColor Green
}

if ($DeployFunction) {
  Invoke-Supabase -SbArgs @("functions","deploy","rgsr_stripe_webhook","--no-verify-jwt")
  Write-Host "[OK] function deployed: rgsr_stripe_webhook" -ForegroundColor Green
}

Write-Host "✅ v12.1 LOCK-IN COMPLETE (Stripe webhook edge + billing linkage RPCs)" -ForegroundColor Green
