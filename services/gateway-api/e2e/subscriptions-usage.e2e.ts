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
import { URL } from 'url';

type Json = any;

function requestJson(method: string, urlStr: string, headers: Record<string, string> = {}): Promise<Json> {
  const url = new URL(urlStr);
  const options: http.RequestOptions = {
    method,
    hostname: url.hostname,
    port: url.port || 80,
    path: url.pathname + url.search,
    headers: {
      'content-type': 'application/json',
      ...headers,
    },
  };

  return new Promise((resolve, reject) => {
    const req = http.request(options, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        try {
          const json = data ? JSON.parse(data) : {};
          if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
            resolve(json);
          } else {
            const err = new Error(`HTTP ${res.statusCode}: ${data}`);
            (err as any).response = json;
            reject(err);
          }
        } catch (e) {
          reject(new Error(`Invalid JSON response: ${e instanceof Error ? e.message : String(e)} | body=${data}`));
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
  const SERVER_URL = process.env.SERVER_URL || 'http://localhost:4000';
  const USER_ID = process.env.USER_ID || '00000000-0000-0000-0000-000000000002';

  const target = new URL('/subscriptions/usage', SERVER_URL).toString();

  const res = await requestJson('GET', target, { 'x-user-id': USER_ID });

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
