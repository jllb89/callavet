#!/usr/bin/env node
/*
  Reconcile Stripe subscriptions vs local DB user_subscriptions.
  Requirements:
    - ENV STRIPE_SECRET_KEY
    - ENV DATABASE_URL (Postgres connection string)
  Usage:
    node scripts/reconcile-stripe-subs.js [--json] [--limit=100]
*/
const { Client } = require('pg');

const stripeKey = process.env.STRIPE_SECRET_KEY;
const dbUrl = process.env.DATABASE_URL;
if (!stripeKey) {
  console.error('Missing STRIPE_SECRET_KEY env');
  process.exit(1);
}
if (!dbUrl) {
  console.error('Missing DATABASE_URL env');
  process.exit(1);
}

const args = process.argv.slice(2);
const asJson = args.includes('--json');
const limitArg = args.find(a => a.startsWith('--limit='));
const limit = limitArg ? Number(limitArg.split('=')[1]) : 100;

async function fetchStripeSubscriptions() {
  const subs = [];
  let url = `https://api.stripe.com/v1/subscriptions?limit=${limit}`;
  while (url) {
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${stripeKey}` },
      method: 'GET'
    });
    if (!res.ok) throw new Error(`Stripe API error ${res.status}`);
    const data = await res.json();
    for (const s of data.data || []) {
      subs.push({
        id: s.id,
        status: s.status,
        current_period_end: s.current_period_end ? new Date(s.current_period_end * 1000) : null,
        cancel_at_period_end: !!s.cancel_at_period_end,
        price_id: s.items?.data?.[0]?.price?.id || null
      });
    }
    if (data.has_more && data.data.length) {
      const lastId = data.data[data.data.length - 1].id;
      url = `https://api.stripe.com/v1/subscriptions?limit=${limit}&starting_after=${lastId}`;
    } else {
      url = null;
    }
  }
  return subs;
}

function buildPgConfig(url) {
  // Avoid pg's built-in sslmode parsing quirks; construct manually.
  const u = new URL(url);
  const cfg = {
    host: u.hostname,
    port: u.port ? Number(u.port) : 5432,
    database: decodeURIComponent(u.pathname.replace(/^\//,'')),
    user: decodeURIComponent(u.username),
    password: decodeURIComponent(u.password),
  };
  const needsSsl = /sslmode=require/.test(url) || /supabase\.co/.test(u.hostname);
  if (needsSsl) {
    cfg.ssl = { rejectUnauthorized: false };
  }
  return cfg;
}

async function fetchDbSubscriptions() {
  const client = new Client(buildPgConfig(dbUrl));
  await client.connect();
  const rs = await client.query(`SELECT stripe_subscription_id as id, status, current_period_end, cancel_at_period_end, plan_id FROM user_subscriptions WHERE stripe_subscription_id IS NOT NULL AND stripe_subscription_id <> ''`);
  await client.end();
  return rs.rows.map(r => ({
    id: r.id,
    status: r.status,
    current_period_end: r.current_period_end,
    cancel_at_period_end: r.cancel_at_period_end,
    plan_id: r.plan_id
  }));
}

function diff(stripeSubs, dbSubs) {
  const stripeMap = new Map(stripeSubs.map(s => [s.id, s]));
  const dbMap = new Map(dbSubs.map(s => [s.id, s]));
  const missingInDb = [];
  const missingInStripe = [];
  const mismatches = [];
  for (const s of stripeSubs) {
    if (!dbMap.has(s.id)) missingInDb.push(s);
  }
  for (const s of dbSubs) {
    if (!stripeMap.has(s.id)) missingInStripe.push(s);
  }
  for (const s of stripeSubs) {
    const d = dbMap.get(s.id);
    if (!d) continue;
    const periodEndDiff = d.current_period_end && s.current_period_end ? Math.abs(new Date(d.current_period_end).getTime() - s.current_period_end.getTime()) : 0;
    if (d.status !== s.status || periodEndDiff > 60000 || !!d.cancel_at_period_end !== !!s.cancel_at_period_end) {
      mismatches.push({
        id: s.id,
        stripe_status: s.status,
        db_status: d.status,
        stripe_period_end: s.current_period_end,
        db_period_end: d.current_period_end,
        period_end_diff_ms: periodEndDiff,
        stripe_cancel_at_period_end: s.cancel_at_period_end,
        db_cancel_at_period_end: d.cancel_at_period_end
      });
    }
  }
  return { missingInDb, missingInStripe, mismatches };
}

(async () => {
  try {
    const [stripeSubs, dbSubs] = await Promise.all([fetchStripeSubscriptions(), fetchDbSubscriptions()]);
    const { missingInDb, missingInStripe, mismatches } = diff(stripeSubs, dbSubs);
    const summary = {
      totals: {
        stripe: stripeSubs.length,
        db: dbSubs.length,
        missing_in_db: missingInDb.length,
        missing_in_stripe: missingInStripe.length,
        mismatches: mismatches.length
      },
      missing_in_db: missingInDb.map(s => ({ id: s.id, status: s.status })),
      missing_in_stripe: missingInStripe.map(s => ({ id: s.id, status: s.status })),
      mismatches
    };
    if (asJson) {
      console.log(JSON.stringify(summary, null, 2));
    } else {
      console.log('Stripe vs DB Subscription Reconciliation');
      console.log('Totals:', summary.totals);
      if (missingInDb.length) console.log('\nMissing in DB:', summary.missing_in_db);
      if (missingInStripe.length) console.log('\nMissing in Stripe:', summary.missing_in_stripe);
      if (mismatches.length) console.log('\nMismatches:', summary.mismatches);
      if (!missingInDb.length && !missingInStripe.length && !mismatches.length) console.log('\nAll subscriptions in sync.');
    }
  } catch (e) {
    console.error('Reconciliation error:', e.message);
    process.exit(1);
  }
})();
