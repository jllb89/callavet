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
  const sig = req.headers["stripe-signature"] as string;
  let event: Stripe.Event;
  try { event = stripe.webhooks.constructEvent(req.body, sig, endpointSecret); }
  catch (e) { return res.sendStatus(400); }

  switch (event.type) {
    case 'customer.subscription.created': {
      const sub = event.data.object as Stripe.Subscription;
      console.log('subscription created', sub.id, sub.status, sub.customer);
      // TODO: initial upsert of subscription record (period start/end, status)
      break;
    }
    case 'checkout.session.completed': {
      const session = event.data.object as Stripe.Checkout.Session;
      console.log('checkout.session.completed', session.id, session.customer);
      // TODO: upsert payment + activate subscription boundaries
      break;
    }
    case 'invoice.payment_succeeded': {
      const invoice = event.data.object as Stripe.Invoice;
      console.log('invoice.payment_succeeded', invoice.id);
      // TODO: record invoice paid
      break;
    }
    case 'invoice.payment_failed': {
      const invoice = event.data.object as Stripe.Invoice;
      console.log('invoice.payment_failed', invoice.id);
      // TODO: flag subscription delinquent
      break;
    }
    case 'customer.subscription.updated':
    case 'customer.subscription.deleted': {
      const sub = event.data.object as Stripe.Subscription;
      console.log('subscription change', event.type, sub.id);
      // TODO: update user_subscriptions periods
      break;
    }
    default:
      console.log('Unhandled event', event.type);
  }

  return res.json({ received: true });
});

app.listen(4200, '0.0.0.0', ()=>console.log("Webhooks :4200"));
