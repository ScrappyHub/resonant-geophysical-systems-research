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
