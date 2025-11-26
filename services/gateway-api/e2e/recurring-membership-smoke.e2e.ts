/*
 E2E: Recurring membership smoke — plan checkout and usage snapshot.
 This uses the DB-backed stub checkout (or Stripe session if configured).
 Requires env: SERVER_URL, AUTH_HEADER, PLAN_CODE (e.g., "basic", "pro").
*/
import https from 'https';

function request(path: string, method = 'GET', body?: any): Promise<any> {
  return new Promise((resolve, reject) => {
    const url = new URL(path.startsWith('http') ? path : `${process.env.SERVER_URL}${path}`);
    const data = body ? JSON.stringify(body) : undefined;
    const req = https.request(
      url,
      {
        method,
        headers: {
          ...(process.env.AUTH_HEADER ? { [process.env.AUTH_HEADER.split(':')[0]]: process.env.AUTH_HEADER.split(':').slice(1).join(':').trim() } : {}),
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
  if (!process.env.SERVER_URL || !process.env.AUTH_HEADER || !process.env.PLAN_CODE) {
    console.error('Set SERVER_URL, AUTH_HEADER, PLAN_CODE');
    process.exit(1);
  }

  const checkout = await request('/subscriptions/checkout', 'POST', { plan_code: process.env.PLAN_CODE });
  console.log('Checkout:', JSON.stringify(checkout));
  if (!checkout.ok) throw new Error('checkout failed');

  const my = await request('/subscriptions/my');
  console.log('My subs:', JSON.stringify(my));

  const usage = await request('/subscriptions/usage/current');
  console.log('Usage:', JSON.stringify(usage));
  if (!usage.ok) throw new Error('usage failed');

  console.log('recurring-membership-smoke.e2e: OK');
}

main().catch((e) => { console.error(e); process.exit(1); });
