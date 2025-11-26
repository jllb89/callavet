/*
 Staging-safe E2E: session start overage scenarios (entitlement exhaustion, optional credit draw, overage fallback).
 No direct DB access; uses only HTTP calls.
 Assumptions:
  - User has an active subscription with at least 1 included chat.
  - Credits may or may not exist for chat_unit.

 Flow:
 1. Fetch current usage.
 2. Start chat sessions until consumed_chats >= included_chats (each should be overage=false).
 3. Start one more session: if credit exists expect overage=false + credit.used, else overage=true.

 Optional manual purchase path:
   Run /subscriptions/overage/checkout (code=chat_unit, original_session_id=<overage session id>) externally, complete Stripe checkout, then rerun script to observe credit usage.

 Env:
   SERVER_URL (defaults to $GATEWAY or http://localhost:4000)
   AUTH_TOKEN (JWT; if set uses Authorization header)
   USER_ID (fallback if AUTH_TOKEN absent)
   DEBUG (verbose logging)
*/

import http from 'http';
import https from 'https';
import { URL } from 'url';

type Json = any;

function req(method: string, path: string, body: any | null, headers: Record<string,string>={}): Promise<{status:number; json:Json}> {
  const SERVER_URL = process.env.SERVER_URL || process.env.GATEWAY || 'http://localhost:4000';
  const url = new URL(path, SERVER_URL);
  const isHttps = url.protocol === 'https:';
  const client = isHttps ? https : http;
  const data = body ? JSON.stringify(body) : '';
  const opts: https.RequestOptions = {
    method,
    hostname: url.hostname,
    port: url.port || (isHttps ? 443 : 80),
    path: url.pathname + url.search,
    headers: {
      'accept': 'application/json',
      'content-type': 'application/json',
      ...(process.env.AUTH_TOKEN ? { authorization: `Bearer ${process.env.AUTH_TOKEN}` } : { 'x-user-id': process.env.USER_ID || '00000000-0000-0000-0000-000000000002' }),
      'content-length': Buffer.byteLength(data).toString(),
      ...headers
    }
  };
  return new Promise((resolve,reject)=>{
    const r = client.request(opts, res => {
      if (res.statusCode && [301,302,307,308].includes(res.statusCode) && res.headers.location) {
        r.destroy();
        return resolve(req(method, res.headers.location!, body, headers));
      }
      let buf='';
      res.on('data', c=> buf+=c);
      res.on('end', ()=>{
        const ct = (res.headers['content-type']||'').toString();
        const looksJson = ct.includes('application/json') && !buf.startsWith('<');
        try {
          const json = looksJson && buf ? JSON.parse(buf) : (looksJson ? {} : { raw: buf });
          resolve({status: res.statusCode||0, json});
        } catch(e:any){ return reject(new Error('Invalid JSON: '+e.message+' body='+buf.substring(0,200))); }
      });
    });
    r.on('error', reject);
    if (data) r.write(data);
    r.end();
  });
}

function assert(cond: any, msg: string): asserts cond { if(!cond) throw new Error('Assertion failed: '+msg); }

function log(...a: any[]){ if(process.env.DEBUG) console.log('[TEST]', ...a); }

async function main(){
  // 1. Initial usage snapshot
  const usageRes = await req('GET', '/subscriptions/usage', null);
  assert(usageRes.json.ok === true, 'usage ok');
  const usage = usageRes.json.usage;
  log('usage initial', usage);
  const includedChats = usage.included_chats;
  let consumedChats = usage.consumed_chats;
  assert(typeof includedChats === 'number' && includedChats >= 0, 'includedChats numeric');
  assert(typeof consumedChats === 'number' && consumedChats >= 0, 'consumedChats numeric');







  // 2. Use entitlements until exhausted
  let safety = 0;
  while (consumedChats < includedChats) {
    const r = await req('POST', '/sessions/start', { kind: 'chat' });
    log('session entitlement', r.json);
    assert(r.json.ok === true, 'entitlement session ok');
    assert(r.json.overage === false, 'should not be overage before exhaustion');
    // Refresh usage
    const u2 = await req('GET', '/subscriptions/usage', null);
    consumedChats = u2.json.usage.consumed_chats;
    if (++safety > includedChats + 5) throw new Error('Loop safety triggered');
  }
  log('entitlements exhausted consumedChats=', consumedChats, 'includedChats=', includedChats);

  // 3. Credits snapshot before overage attempt
  const creditsRes = await req('GET', '/subscriptions/overage/credits', null);
  const chatCredit = Array.isArray(creditsRes.json.credits) ? creditsRes.json.credits.find((c:any)=>c.code==='chat_unit' && c.remaining_units>0) : null;
  log('credits before final start', creditsRes.json);

  // 4. Post-exhaustion session start
  const post = await req('POST', '/sessions/start', { kind: 'chat' });
  log('post-exhaustion session', post.json);
  assert(post.json.ok === true, 'post session ok');
  if (chatCredit) {
    assert(post.json.overage === false, 'expected credit draw (not overage)');
    assert(post.json.credit && post.json.credit.used === true, 'credit should be used');
  } else {
    assert(post.json.overage === true, 'expected overage prompt (no credit)');
  }

  console.log('PASS: staging overage-credit-draw');
}

main().catch(err => { console.error('FAIL: overage-credit-draw scenarios'); console.error(err.stack||err.message||String(err)); process.exit(1); });
