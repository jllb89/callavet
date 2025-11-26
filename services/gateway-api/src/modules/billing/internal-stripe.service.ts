import { Injectable } from '@nestjs/common';
import { DbService } from '../db/db.service';
import crypto from 'node:crypto';

interface IncomingStripeEvent {
  id: string;
  type: string;
  data: any; // raw stripe object
}

@Injectable()
export class InternalStripeService {
  constructor(private readonly db: DbService) {}

  // Resolve plan (id + code) from Stripe price id using DB (no env vars)
  private async resolvePlanFromPrice(priceId?: string): Promise<{ id: string; code: string } | undefined> {
    if (!priceId) return undefined;
    // First: flexible pricing table (supports multi-currency/period)
    const flex = await this.db.query<{ id: string; code: string }>(
      `select sp.id, sp.code
         from subscription_plan_prices spp
         join subscription_plans sp on sp.id = spp.plan_id
        where spp.is_active
          and sp.is_active
          and spp.stripe_price_id = $1
        limit 1`,
      [priceId]
    );
    if (flex.rows[0]) return flex.rows[0];
    // Fallback: legacy single price columns on subscription_plans
    const legacy = await this.db.query<{ id: string; code: string }>(
      `select id, code
         from subscription_plans
        where is_active
          and stripe_price_id = $1
        limit 1`,
      [priceId]
    );
    return legacy.rows[0] || undefined;
  }

  async processEvent(evt: IncomingStripeEvent) {
    // Idempotency insert
    await this.db.ensureReady();
    const inserted = await this.db.query<{ event_id: string }>(
      `INSERT INTO stripe_subscription_events (event_id, type, stripe_subscription_id) VALUES ($1,$2,$3) ON CONFLICT DO NOTHING RETURNING event_id`,
      [evt.id, evt.type, this.extractSubscriptionId(evt)]
    );
    if (!inserted.rows.length) {
      return { skipped: true, reason: 'duplicate' };
    }

    switch (evt.type) {
      case 'customer.subscription.created':
      case 'customer.subscription.updated':
      case 'customer.subscription.deleted':
        return this.handleSubscription(evt);
      case 'invoice.payment_succeeded':
        return this.handleInvoicePayment(evt, true);
      case 'invoice.payment_failed':
        return this.handleInvoicePayment(evt, false);
      case 'checkout.session.completed':
        return this.handleCheckoutSession(evt);
      case 'payment_intent.succeeded':
        return this.handlePaymentIntentSucceeded(evt);
      default:
        return { ok: true, unhandled: evt.type };
    }
  }

  private extractSubscriptionId(evt: IncomingStripeEvent): string | null {
    const o = evt.data || {};
    if (evt.type.startsWith('customer.subscription')) return o.id || null;
    if (evt.type.startsWith('invoice.') && o.subscription) return o.subscription;
    return null;
  }

  private async handleSubscription(evt: IncomingStripeEvent) {
    const sub = evt.data || {};
    const stripeSubId: string = sub.id;
    const stripeCustomerId: string = sub.customer;
    const periodStart = sub.current_period_start ? Number(sub.current_period_start) : null;
    const periodEnd = sub.current_period_end ? Number(sub.current_period_end) : null;
    const status: string = sub.status;
    const stripeCanceledAt: number | null = sub.canceled_at ? Number(sub.canceled_at) : null;
    const stripeCancelAt: number | null = sub.cancel_at ? Number(sub.cancel_at) : null;
    // Derive cancel flag: true if explicit boolean true OR cancel_at timestamp present; false if explicit false; otherwise null (no change)
    const cancelAtPeriodEnd: boolean | null =
      sub.cancel_at_period_end === true || !!stripeCancelAt ? true :
      (sub.cancel_at_period_end === false ? false : null);

    // Determine plan code via first line item's price id
    let priceId: string | undefined;
    if (sub.items && sub.items.data && sub.items.data.length > 0) {
      priceId = sub.items.data[0]?.price?.id;
    }
    const plan = await this.resolvePlanFromPrice(priceId);
    if (process.env.DEV_DB_DEBUG === '1') {
      // eslint-disable-next-line no-console
      console.log('[internal-stripe] handleSubscription evt=', evt.type, 'subId=', stripeSubId, 'priceId=', priceId, 'planResolved=', plan?.code || null);
    }
    const planCode = plan?.code;
    const planId = plan?.id;

    // Build dynamic SET clause with stable placeholder indexing (no filtering afterwards)
    const setFrags: string[] = [];
    const values: any[] = [];
    const pushVal = (columnSql: string, value: any, transformTimestamp?: boolean) => {
      const idx = values.length + 1;
      if (transformTimestamp) {
        setFrags.push(`${columnSql}=to_timestamp($${idx})`);
      } else {
        setFrags.push(`${columnSql}=$${idx}`);
      }
      values.push(value);
    };
    const mappedStatus = this.mapStatus(status);
    pushVal('status', mappedStatus);
    if (periodStart) pushVal('current_period_start', periodStart, true);
    if (periodEnd) pushVal('current_period_end', periodEnd, true);
    pushVal('stripe_customer_id', stripeCustomerId);
    pushVal('stripe_subscription_id', stripeSubId);
    // Legacy mirrors
    pushVal('provider_customer_id', stripeCustomerId);
    pushVal('provider_subscription_id', stripeSubId);
    if (planId) pushVal('plan_id', planId);
    if (cancelAtPeriodEnd !== null) pushVal('cancel_at_period_end', cancelAtPeriodEnd);
    if (mappedStatus === 'canceled' && stripeCanceledAt) {
      pushVal('canceled_at', stripeCanceledAt, true);
      pushVal('auto_renew', false);
    }
    // updated_at without placeholder
    setFrags.push('updated_at=now()');

    // Attempt update by stripe_subscription_id first
    const sqlBySub = `UPDATE user_subscriptions SET ${setFrags.join(', ')} WHERE stripe_subscription_id=$${values.length+1} RETURNING id`;
    const bySub = await this.db.query<{ id: string }>(sqlBySub, [...values, stripeSubId]);
    if (bySub.rows.length) {
      return { ok: true, updated: bySub.rows.length, mode: 'by_subscription_id' };
    }

    // Attempt update by customer id where subscription id missing
    const sqlByCustomer = `UPDATE user_subscriptions SET ${setFrags.join(', ')} WHERE stripe_customer_id=$${values.length+1} AND (stripe_subscription_id IS NULL OR stripe_subscription_id='') RETURNING id`;
    const byCust = await this.db.query<{ id: string }>(sqlByCustomer, [...values, stripeCustomerId]);
    if (byCust.rows.length) {
      return { ok: true, updated: byCust.rows.length, mode: 'by_customer_id' };
    }

    // Fallback insert if we can resolve user_id via stripe_customers mapping
    const userLookup = await this.db.query<{ user_id: string }>(`SELECT user_id FROM stripe_customers WHERE stripe_customer_id=$1 LIMIT 1`, [stripeCustomerId]);
    const userId = userLookup.rows[0]?.user_id;
    // Attempt synthetic period inference if missing (Stripe object sometimes lacks fields in slim payloads)
    let inferredStart = periodStart;
    let inferredEnd = periodEnd;
    if (!inferredStart) inferredStart = Math.floor(Date.now() / 1000);
    if (!inferredEnd) {
      // Try derive from recurring interval of first item
      const interval = (sub.items?.data?.[0]?.price?.recurring?.interval) || 'month';
      const base = inferredStart || Math.floor(Date.now() / 1000);
      const monthSecs = 30 * 24 * 3600; // acceptable approximation; real end will be corrected on next webhook
      const yearSecs = 365 * 24 * 3600;
      inferredEnd = base + (interval === 'year' ? yearSecs : monthSecs);
    }
    if (!userId || !planId || !inferredStart || !inferredEnd) {
      if (process.env.DEV_DB_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.warn('[internal-stripe] fallback_insert skipped userId=', userId, 'planId=', planId, 'inferredStart=', inferredStart, 'inferredEnd=', inferredEnd);
      }
      return { ok: true, updated: 0, warning: 'no_matching_row_and_missing_context' };
    }
    const newId = this.newUuid();
    await this.db.query(`INSERT INTO user_subscriptions (
        id, user_id, plan_id, status, current_period_start, current_period_end,
        cancel_at_period_end, stripe_subscription_id, stripe_customer_id,
        provider_subscription_id, provider_customer_id, auto_renew, created_at, updated_at
      ) VALUES (
        $1,$2,$3,$4,to_timestamp($5),to_timestamp($6),$7,$8,$9,$8,$9,true, now(), now()
      ) ON CONFLICT DO NOTHING`, [
        newId,
        userId,
        planId,
        mappedStatus,
        inferredStart,
        inferredEnd,
        cancelAtPeriodEnd === null ? false : cancelAtPeriodEnd,
        stripeSubId,
        stripeCustomerId
      ]);
    return { ok: true, inserted: 1, mode: 'fallback_insert' };
  }

  private async handleInvoicePayment(evt: IncomingStripeEvent, succeeded: boolean) {
    const invoice = evt.data || {};
    const subscriptionId = invoice.subscription;
    if (!subscriptionId) return { ok: true, ignored: 'invoice_no_subscription' };
    const status = succeeded ? 'active' : 'past_due';
    const res = await this.db.query<{ id: string }>(`UPDATE user_subscriptions SET status=$2, updated_at=now() WHERE stripe_subscription_id=$1 RETURNING id`, [subscriptionId, status]);
    return { ok: true, updated: res.rows.length, statusApplied: status };
  }

  private mapStatus(stripeStatus: string): string {
    switch (stripeStatus) {
      case 'trialing': return 'trialing';
      case 'active': return 'active';
      case 'past_due': return 'past_due';
      case 'canceled': return 'canceled';
      case 'incomplete':
      case 'incomplete_expired':
      case 'unpaid': return 'past_due';
      default: return 'active';
    }
  }

  private async handleCheckoutSession(evt: IncomingStripeEvent) {
    const session = evt.data || {};
    const stripeCustomerId: string | undefined = session.customer;
    const userId: string | undefined = session.metadata?.user_id;
    const overageCode: string | undefined = session.metadata?.overage_item_code;
    const originalSessionId: string | undefined = session.metadata?.original_session_id;
    const sessionId: string | undefined = session.id;
    const paymentIntentId: string | undefined = typeof session.payment_intent === 'string' ? session.payment_intent : (session.payment_intent?.id || undefined);
    // Do not require Stripe customer for overage one-off flows; proceed if we have session metadata
    if (userId && stripeCustomerId) {
      await this.db.query(`INSERT INTO stripe_customers (user_id, stripe_customer_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`, [userId, stripeCustomerId]);
    }
    // If this was an overage checkout, mark purchase paid and apply side-effects
    if (sessionId) {
      const res = await this.db.runInTx(async (q) => {
        const upd = await q<any>(
          `update overage_purchases
              set status = 'paid',
                  stripe_payment_intent_id = coalesce(stripe_payment_intent_id, $2),
                  updated_at = now()
            where stripe_checkout_session_id = $1
            returning id, user_id, overage_item_id, quantity, original_session_id`,
          [sessionId, paymentIntentId || null]
        );
        if (!upd.rows[0]) return { matched: 0 } as any;
        const p = upd.rows[0];
        // If original_session_id present, auto-consume one unit immediately
        if (p.original_session_id) {
          // Ensure we don't duplicate consumption for this purchase
          const exists = await q<{ id: string }>(`select id from entitlement_consumptions where overage_purchase_id = $1 limit 1`, [p.id]);
          if (!exists.rows[0]) {
            // Resolve consumption type from item metadata or code
            const { rows: items } = await q<any>(`select code, coalesce((metadata->>'type')::text,'') as meta_type from overage_items where id = $1`, [p.overage_item_id]);
            const code = (items[0]?.code || '').toString();
            const mtype = (items[0]?.meta_type || '').toString();
            const t = mtype || (code.includes('video') ? 'video' : code.includes('chat') ? 'chat' : code.includes('sms') ? 'sms' : 'emergency');
            // Find active subscription for user
            const { rows: subs } = await q<{ id: string }>(
              `select id
                 from user_subscriptions
                where user_id = $1::uuid
                  and status = 'active'
                  and coalesce(current_period_end, now()) > now()
                order by current_period_end desc nulls last
                limit 1`,
              [p.user_id]
            );
            if (subs[0]) {
              await q(
                `insert into entitlement_consumptions (id, subscription_id, session_id, consumption_type, amount, source, created_at, overage_purchase_id)
                 values (gen_random_uuid(), $1::uuid, $2::uuid, $3::text, 1, 'overage', now(), $4::uuid)
                 on conflict do nothing`,
                [subs[0].id, p.original_session_id, t, p.id]
              );
              // Mark purchase consumed
              await q(`update overage_purchases set status='consumed', updated_at=now() where id=$1`, [p.id]);
            } else {
              // No active subscription: credit the units for later
              await q(
                `insert into overage_credits (user_id, overage_item_id, remaining_units)
                 values ($1::uuid, $2::uuid, $3)
                 on conflict (user_id, overage_item_id)
                 do update set remaining_units = overage_credits.remaining_units + EXCLUDED.remaining_units, updated_at=now()`,
                [p.user_id, p.overage_item_id, p.quantity]
              );
              await q(`update overage_purchases set status='credited', updated_at=now() where id=$1`, [p.id]);
            }
          }
        } else {
          // No session binding: credit the units
          await q(
            `insert into overage_credits (user_id, overage_item_id, remaining_units)
             values ($1::uuid, $2::uuid, $3)
             on conflict (user_id, overage_item_id)
             do update set remaining_units = overage_credits.remaining_units + EXCLUDED.remaining_units, updated_at=now()`,
            [p.user_id, p.overage_item_id, p.quantity]
          );
          await q(`update overage_purchases set status='credited', updated_at=now() where id=$1`, [p.id]);
        }
        return { matched: 1, purchase_id: p.id } as any;
      });
      return { ok: true, session: sessionId, overage: res };
    }
    return { ok: true, session: session.id, mapped: !!userId };
  }

  private async handlePaymentIntentSucceeded(evt: IncomingStripeEvent) {
    const pi = evt.data || {};
    const piId: string | undefined = pi.id;
    if (!piId) return { ok: true, ignored: 'no_payment_intent_id' };
    // Update purchase by payment intent id if present
    const res = await this.db.runInTx(async (q) => {
      const upd = await q<any>(
        `update overage_purchases
            set status = 'paid',
                updated_at = now()
          where stripe_payment_intent_id = $1
          returning id, user_id, overage_item_id, quantity, original_session_id`,
        [piId]
      );
      if (!upd.rows[0]) return { matched: 0 } as any;
      const p = upd.rows[0];
      // If not yet consumed/credited, apply same side-effects as in checkout.session.completed
      const exists = await q<{ id: string }>(`select id from entitlement_consumptions where overage_purchase_id=$1 limit 1`, [p.id]);
      if (exists.rows[0]) return { matched: 1, alreadyConsumed: true } as any;
      if (p.original_session_id) {
        const { rows: items } = await q<any>(`select code, coalesce((metadata->>'type')::text,'') as meta_type from overage_items where id = $1`, [p.overage_item_id]);
        const code = (items[0]?.code || '').toString();
        const mtype = (items[0]?.meta_type || '').toString();
        const t = mtype || (code.includes('video') ? 'video' : code.includes('chat') ? 'chat' : code.includes('sms') ? 'sms' : 'emergency');
        const { rows: subs } = await q<{ id: string }>(
          `select id from user_subscriptions where user_id=$1::uuid and status='active' and coalesce(current_period_end, now()) > now() order by current_period_end desc nulls last limit 1`,
          [p.user_id]
        );
        if (subs[0]) {
          await q(
            `insert into entitlement_consumptions (id, subscription_id, session_id, consumption_type, amount, source, created_at, overage_purchase_id)
             values (gen_random_uuid(), $1::uuid, $2::uuid, $3::text, 1, 'overage', now(), $4::uuid)
             on conflict do nothing`,
            [subs[0].id, p.original_session_id, t, p.id]
          );
          await q(`update overage_purchases set status='consumed', updated_at=now() where id=$1`, [p.id]);
        } else {
          await q(
            `insert into overage_credits (user_id, overage_item_id, remaining_units)
             values ($1::uuid, $2::uuid, $3)
             on conflict (user_id, overage_item_id)
             do update set remaining_units = overage_credits.remaining_units + EXCLUDED.remaining_units, updated_at=now()`,
            [p.user_id, p.overage_item_id, p.quantity]
          );
          await q(`update overage_purchases set status='credited', updated_at=now() where id=$1`, [p.id]);
        }
      } else {
        await q(
          `insert into overage_credits (user_id, overage_item_id, remaining_units)
           values ($1::uuid, $2::uuid, $3)
           on conflict (user_id, overage_item_id)
           do update set remaining_units = overage_credits.remaining_units + EXCLUDED.remaining_units, updated_at=now()`,
          [p.user_id, p.overage_item_id, p.quantity]
        );
        await q(`update overage_purchases set status='credited', updated_at=now() where id=$1`, [p.id]);
      }
      return { matched: 1 } as any;
    });
    return { ok: true, payment_intent: piId, overage: res };
  }

  private newUuid(): string {
    if ((crypto as any).randomUUID) return (crypto as any).randomUUID();
    return crypto.randomBytes(16).toString('hex');
  }
}
