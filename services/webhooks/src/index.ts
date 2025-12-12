import express from "express";
import Stripe from "stripe";
import bodyParser from "body-parser";
const app = express();
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY || "", { apiVersion: "2024-06-20" });
const endpointSecret = process.env.STRIPE_WEBHOOK_SECRET || "";

// Health
app.get("/health", (_req,res)=>res.json({ok:true, service:'webhooks'}));

// Stripe Webhooks
app.post("/stripe/webhook", bodyParser.raw({ type: "application/json" }), (req, res) => {
  if (!endpointSecret) {
    console.error('[stripe-webhook] Missing STRIPE_WEBHOOK_SECRET env');
    return res.status(500).json({ ok: false, reason: 'webhook_secret_missing' });
  }
  const sig = req.headers["stripe-signature"] as string;
  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(req.body, sig, endpointSecret);
  } catch (e: any) {
    console.error('[stripe-webhook] signature verification failed', e?.message);
    return res.status(400).json({ ok: false, reason: 'signature_verification_failed' });
  }

  // Forward selected events to internal gateway for persistence
  async function forwardToGateway(event: Stripe.Event) {
    const gatewayUrl = process.env.GATEWAY_INTERNAL_URL; // e.g. http://gateway-api:3000/internal/stripe/event
    const secret = process.env.INTERNAL_STRIPE_EVENT_SECRET;
    if (!gatewayUrl) return console.warn('[stripe-webhook] GATEWAY_INTERNAL_URL not set, skipping forward');
    if (!secret) return console.warn('[stripe-webhook] INTERNAL_STRIPE_EVENT_SECRET not set, skipping forward');
    // Minimal payload; gateway will pull required fields
    const payload = { id: event.id, type: event.type, data: event.data.object };
    const started = Date.now();
    console.log('[stripe-webhook] forward start', event.id, event.type);
    try {
      const res = await fetch(gatewayUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-internal-secret': secret },
        body: JSON.stringify(payload),
      });
      const ms = Date.now() - started;
      if (!res.ok) {
        const text = await res.text();
        console.error('[stripe-webhook] forward error', event.id, event.type, res.status, `${ms}ms`, text.slice(0,200));
      } else {
        console.log('[stripe-webhook] forward ok', event.id, event.type, res.status, `${ms}ms`);
      }
    } catch (err: any) {
      const ms = Date.now() - started;
      console.error('[stripe-webhook] forward exception', event.id, event.type, `${ms}ms`, err?.message);
    }
  }

  switch (event.type) {
    case 'customer.subscription.created': {
      const sub = event.data.object as Stripe.Subscription;
      console.log('[stripe-webhook] subscription created', sub.id, sub.status, sub.customer);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'checkout.session.completed': {
      const session = event.data.object as Stripe.Checkout.Session;
      console.log('[stripe-webhook] checkout.session.completed', session.id, session.customer);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'payment_intent.succeeded': {
      const pi = event.data.object as Stripe.PaymentIntent;
      console.log('[stripe-webhook] payment_intent.succeeded', pi.id, pi.amount, pi.currency);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'payment_intent.payment_failed': {
      const pi = event.data.object as Stripe.PaymentIntent;
      console.log('[stripe-webhook] payment_intent.payment_failed', pi.id);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'charge.refunded':
    case 'charge.refund.updated': {
      const ch = event.data.object as Stripe.Charge;
      console.log('[stripe-webhook] charge refund event', event.type, ch.id, ch.payment_intent);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'invoice.payment_succeeded': {
      const invoice = event.data.object as Stripe.Invoice;
      console.log('[stripe-webhook] invoice.payment_succeeded', invoice.id);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'invoice.payment_failed': {
      const invoice = event.data.object as Stripe.Invoice;
      console.log('[stripe-webhook] invoice.payment_failed', invoice.id);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted': {
      const sub = event.data.object as Stripe.Subscription;
      console.log('[stripe-webhook] subscription change', event.type, sub.id);
      forwardToGateway(event).catch((e)=>console.error('[stripe-webhook] forward failed', e?.message));
      break;
    }
    default:
      console.log('[stripe-webhook] Unhandled event', event.type);
  }
  return res.json({ ok: true, received: true });
});

app.listen(4200, '0.0.0.0', ()=>console.log("Webhooks :4200"));
