/*
 Simulate a Stripe charge.refunded webhook to test refund handler.
 Usage:
   SERVER_URL=http://localhost:4000 PAYMENT_INTENT_ID=pi_test123 pnpm -F @cav/gateway-api ts-node e2e/refund-webhook-sim.ts
 Requires the gateway webhook endpoint (adjust path if different).
*/
import http from 'http';
import { URL } from 'url';

const SERVER_URL = process.env.SERVER_URL || 'http://localhost:4000';
const PAYMENT_INTENT_ID = process.env.PAYMENT_INTENT_ID || 'pi_dummy';
const path = '/internal/stripe/webhook'; // adjust if actual route differs

// Minimal Stripe-like refund event payload
const evt = {
  id: 'evt_refund_sim_' + Date.now(),
  type: 'charge.refunded',
  data: {
    id: 'ch_dummy',
    object: 'charge',
    payment_intent: PAYMENT_INTENT_ID,
    amount_refunded: 100,
  }
};

function send(){
  const url = new URL(path, SERVER_URL);
  const body = JSON.stringify(evt);
  const opts: http.RequestOptions = {
    method: 'POST',
    hostname: url.hostname,
    port: url.port || 80,
    path: url.pathname + url.search,
    headers: {
      'content-type':'application/json',
      'stripe-signature':'simulated',
      'content-length': Buffer.byteLength(body).toString()
    }
  };
  const req = http.request(opts, res => {
    let data='';
    res.on('data', c=> data+=c);
    res.on('end', ()=>{
      console.log('Status', res.statusCode);
      console.log('Body', data);
    });
  });
  req.on('error', e=>{
    console.error('Error', e);
  });
  req.write(body);
  req.end();
}

send();
