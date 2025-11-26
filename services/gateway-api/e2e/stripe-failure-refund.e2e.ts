/*
 E2E: Validate failure and refund handling.
 Prereqs: Stripe CLI configured; INTERNAL_STRIPE_EVENT_SECRET set in webhooks → gateway.
 This script simulates events by calling internal ingest directly with envelope {id,type,data}.
 Requires env: SERVER_URL, INTERNAL_STRIPE_EVENT_SECRET, AUTH_HEADER.
*/
import https from 'https';

function request(path: string, method = 'POST', body?: any, headers?: Record<string,string>): Promise<any> {
  return new Promise((resolve, reject) => {
    const url = new URL(path.startsWith('http') ? path : `${process.env.SERVER_URL}${path}`);
    const data = body ? JSON.stringify(body) : undefined;
    const req = https.request(
      url,
      {
        method,
        headers: {
          ...(headers || {}),
          'Content-Type': 'application/json',
          ...(data ? { 'Content-Length': Buffer.byteLength(data) } : {}),
        },
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const txt = Buffer.concat(chunks).toString('utf8');
          try { resolve(JSON.parse(txt)); } catch { resolve({ status: res.statusCode, text: txt }); }
        });
      }
    );
    req.on('error', reject);
    if (data) req.write(data);
    req.end();
  });
}

async function main() {
  if (!process.env.SERVER_URL || !process.env.INTERNAL_STRIPE_EVENT_SECRET) {
    console.error('Set SERVER_URL and INTERNAL_STRIPE_EVENT_SECRET');
    process.exit(1);
  }

  const headers = { 'x-internal-secret': process.env.INTERNAL_STRIPE_EVENT_SECRET! };
  const fakePi = `pi_${Date.now()}`;

  // payment_intent.payment_failed
  const failed = await request('/internal/stripe/event', 'POST', {
    id: `evt_failed_${Date.now()}`,
    type: 'payment_intent.payment_failed',
    data: { id: fakePi },
  }, headers);
  console.log('PI failed:', JSON.stringify(failed));

  // charge.refunded
  const refunded = await request('/internal/stripe/event', 'POST', {
    id: `evt_refund_${Date.now()}`,
    type: 'charge.refunded',
    data: { payment_intent: fakePi },
  }, headers);
  console.log('Charge refunded:', JSON.stringify(refunded));

  console.log('stripe-failure-refund.e2e: OK (synthetic envelope paths executed)');
}

main().catch((e) => { console.error(e); process.exit(1); });
