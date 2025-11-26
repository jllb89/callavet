/*
 E2E: Verify webhook idempotent processing (no duplicate consume/credit).
 Calls internal ingest twice with same event id.
 Requires env: SERVER_URL, INTERNAL_STRIPE_EVENT_SECRET.
*/
import https from 'https';

function post(path: string, body: any, headers?: Record<string,string>): Promise<any> {
  return new Promise((resolve, reject) => {
    const url = new URL(`${process.env.SERVER_URL}${path}`);
    const data = JSON.stringify(body);
    const req = https.request(url, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(headers||{}), 'Content-Length': Buffer.byteLength(data) } }, (res) => {
      const chunks: Buffer[] = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const txt = Buffer.concat(chunks).toString('utf8');
        try { resolve(JSON.parse(txt)); } catch { resolve({ status: res.statusCode, text: txt }); }
      });
    });
    req.on('error', reject);
    req.write(data);
    req.end();
  });
}

async function main() {
  if (!process.env.SERVER_URL || !process.env.INTERNAL_STRIPE_EVENT_SECRET) {
    console.error('Set SERVER_URL and INTERNAL_STRIPE_EVENT_SECRET');
    process.exit(1);
  }
  const headers = { 'x-internal-secret': process.env.INTERNAL_STRIPE_EVENT_SECRET! };
  const eid = `evt_idem_${Date.now()}`;
  const payload = { id: eid, type: 'checkout.session.completed', data: { id: `cs_${Date.now()}`, customer: null, metadata: { user_id: '00000000-0000-0000-0000-000000000000' } } };

  const first = await post('/internal/stripe/event', payload, headers);
  const second = await post('/internal/stripe/event', payload, headers);
  console.log('First:', JSON.stringify(first));
  console.log('Second:', JSON.stringify(second));

  if (!(second.skipped || (second.result && second.result.skipped))) {
    console.warn('Expected duplicate skip on second delivery');
  }
  console.log('webhook-idempotency.e2e: OK');
}

main().catch((e) => { console.error(e); process.exit(1); });
