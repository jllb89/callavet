/*
 E2E test: verifies auth.uid() propagation and visible usage for active subscription.
 Requires the gateway server running locally (default http://localhost:4000).
 Usage:
   pnpm -F @cav/gateway-api run e2e:subscriptions
 Env:
   SERVER_URL (default: http://localhost:4000)
   USER_ID (default: 00000000-0000-0000-0000-000000000002)
*/

import http from 'http';
import https from 'https';
import { URL } from 'url';

type Json = any;

function requestJson(method: string, urlStr: string, headers: Record<string, string> = {}): Promise<Json> {
  const u = new URL(urlStr);
  const isHttps = u.protocol === 'https:';
  const client = isHttps ? https : http;
  const options: https.RequestOptions = {
    method,
    hostname: u.hostname,
    port: u.port || (isHttps ? 443 : 80),
    path: u.pathname + u.search,
    headers: {
      'accept': 'application/json',
      'content-type': 'application/json',
      ...headers,
    },
  };
  return new Promise((resolve, reject) => {
    const req = client.request(options, (res) => {
      // Follow up to one redirect manually (301/302/307/308)
      if (res.statusCode && [301,302,307,308].includes(res.statusCode) && res.headers.location) {
        req.destroy();
        return resolve(requestJson(method, res.headers.location!, headers));
      }
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        const ct = (res.headers['content-type'] || '').toString();
        const looksJson = ct.includes('application/json') && !data.startsWith('<');
        try {
          const json = looksJson && data ? JSON.parse(data) : (looksJson ? {} : { raw: data });
          if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) return resolve(json);
          const err = new Error(`HTTP ${res.statusCode}: ${data}`);
          (err as any).response = json;
          return reject(err);
        } catch (e:any) {
          return reject(new Error(`Invalid JSON response: ${e.message} | body=${data.substring(0,200)}`));
        }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

function assert(condition: any, msg: string): asserts condition {
  if (!condition) {
    throw new Error(`Assertion failed: ${msg}`);
  }
}

async function main() {
  const SERVER_URL = process.env.SERVER_URL || process.env.GATEWAY || 'http://localhost:4000';
  const USER_ID = process.env.USER_ID || '00000000-0000-0000-0000-000000000002';

  const target = new URL('/subscriptions/usage', SERVER_URL).toString();

  const authHeaders = process.env.AUTH_TOKEN ? { Authorization: `Bearer ${process.env.AUTH_TOKEN}` } : { 'x-user-id': USER_ID };
  const res = await requestJson('GET', target, authHeaders);

  assert(res && res.ok === true, 'response.ok should be true');
  assert(res.msg === 'ok', `expected msg=ok, got ${res.msg}`);
  assert(res.usage && typeof res.usage === 'object', 'usage should be an object');

  const u = res.usage;
  for (const k of ['included_chats', 'consumed_chats', 'included_videos', 'consumed_videos']) {
    assert(typeof u[k] === 'number', `${k} should be a number`);
  }
  assert(u.included_chats >= u.consumed_chats, 'included_chats should be >= consumed_chats');
  assert(u.included_videos >= u.consumed_videos, 'included_videos should be >= consumed_videos');

  console.log('PASS: /subscriptions/usage e2e');
}

main().catch((err) => {
  console.error('FAIL: /subscriptions/usage e2e');
  console.error(err?.stack || err?.message || String(err));
  process.exit(1);
});
