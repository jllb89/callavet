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
    const cancelAtPeriodEnd: boolean | null = typeof sub.cancel_at_period_end === 'boolean' ? sub.cancel_at_period_end : null;
    const stripeCanceledAt: number | null = sub.canceled_at ? Number(sub.canceled_at) : null;

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

    // Build dynamic SET clause
    const setFrags: string[] = [];
    const values: any[] = [];
    const push = (sql: string, val: any) => { setFrags.push(sql); values.push(val); };
    const mappedStatus = this.mapStatus(status);
    push(`status=$${values.length+1}`, mappedStatus);
    if (periodStart) push(`current_period_start=to_timestamp($${values.length+1})`, periodStart);
    if (periodEnd) push(`current_period_end=to_timestamp($${values.length+1})`, periodEnd);
    push(`stripe_customer_id=$${values.length+1}`, stripeCustomerId);
    push(`stripe_subscription_id=$${values.length+1}`, stripeSubId);
    // Mirror legacy provider_* for backwards compatibility
    push(`provider_customer_id=$${values.length+1}`, stripeCustomerId);
    push(`provider_subscription_id=$${values.length+1}`, stripeSubId);
    if (planId) push(`plan_id=$${values.length+1}`, planId);
    if (cancelAtPeriodEnd !== null) push(`cancel_at_period_end=$${values.length+1}`, cancelAtPeriodEnd);
    if (mappedStatus === 'canceled' && stripeCanceledAt) {
      push(`canceled_at=to_timestamp($${values.length+1})`, stripeCanceledAt);
      push(`auto_renew=$${values.length+1}`, false);
    }
    push(`updated_at=now()`, null); // will ignore value

    // Filter out null placeholder value (for updated_at)
    const filteredValues = values.filter(v => v !== null);

    // Attempt update by stripe_subscription_id first
    const sqlBySub = `UPDATE user_subscriptions SET ${setFrags.join(', ')} WHERE stripe_subscription_id=$${filteredValues.length+1} RETURNING id`;
    const bySub = await this.db.query<{ id: string }>(sqlBySub, [...filteredValues, stripeSubId]);
    if (bySub.rows.length) {
      return { ok: true, updated: bySub.rows.length, mode: 'by_subscription_id' };
    }

    // Attempt update by customer id where subscription id missing
    const sqlByCustomer = `UPDATE user_subscriptions SET ${setFrags.join(', ')} WHERE stripe_customer_id=$${filteredValues.length+1} AND (stripe_subscription_id IS NULL OR stripe_subscription_id='') RETURNING id`;
    const byCust = await this.db.query<{ id: string }>(sqlByCustomer, [...filteredValues, stripeCustomerId]);
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
    if (!stripeCustomerId) return { ok: true, ignored: 'no_customer_in_session' };
    if (userId) {
      await this.db.query(`INSERT INTO stripe_customers (user_id, stripe_customer_id) VALUES ($1,$2) ON CONFLICT DO NOTHING`, [userId, stripeCustomerId]);
    }
    return { ok: true, session: session.id, mapped: !!userId };
  }

  private newUuid(): string {
    if ((crypto as any).randomUUID) return (crypto as any).randomUUID();
    return crypto.randomBytes(16).toString('hex');
  }
}
