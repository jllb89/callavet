/*
 Staging-safe E2E: verifies auto credit draw for video sessions.
 Requires env: SERVER_URL, AUTH_HEADER (e.g., "Authorization: Bearer ...").
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
  if (!process.env.SERVER_URL || !process.env.AUTH_HEADER) {
    console.error('Set SERVER_URL and AUTH_HEADER in env');
    process.exit(1);
  }

  const pre = await request('/subscriptions/overage/credits');
  console.log('Credits (before):', JSON.stringify(pre));

  const start = await request('/sessions/start', 'POST', { type: 'video' });
  console.log('Start:', JSON.stringify(start));
  if (!start.ok) throw new Error('start failed');
  if (start.overage) throw new Error('expected credit usage, got overage');
  if (!start.credit?.used) throw new Error('expected credit.used=true');

  const post = await request('/subscriptions/overage/credits');
  console.log('Credits (after):', JSON.stringify(post));
  const code = start.credit?.code;
  const prevUnits = (pre.credits || []).find((c: any) => c.code === code)?.remaining_units ?? null;
  const afterUnits = (post.credits || []).find((c: any) => c.code === code)?.remaining_units ?? null;
  if (prevUnits == null || afterUnits == null) throw new Error('missing credit entries');
  if (afterUnits !== prevUnits - 1) throw new Error(`expected remaining_units to decrement by 1 (was ${prevUnits}, now ${afterUnits})`);

  const end = await request('/sessions/end', 'POST', { sessionId: start.sessionId, consumptionId: start.consumptionId });
  console.log('End:', JSON.stringify(end));
  if (!end.ok || !end.ended) throw new Error('end failed');

  console.log('video-credit-draw.e2e: OK');
}

main().catch((e) => { console.error(e); process.exit(1); });
