import { Body, Controller, Get, HttpException, HttpStatus, Post, Query, UseGuards, Req } from '@nestjs/common';
import { PriceService } from './price.service';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';

@Controller('subscriptions')
@UseGuards(AuthGuard)
export class SubscriptionsController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext, private readonly prices: PriceService) {}

  @Post('apple/verify')
  async appleVerify(
    @Body()
    body: {
      event_id?: string;
      event_type?: string;
      environment?: 'sandbox' | 'production';
      original_transaction_id?: string;
      transaction_id?: string;
      product_id?: string;
      app_account_token?: string;
      status?: 'trialing' | 'active' | 'past_due' | 'canceled' | 'expired';
      current_period_start?: string;
      current_period_end?: string;
      cancel_at_period_end?: boolean;
      auto_renew?: boolean;
      signed_payload?: string;
      payload?: any;
    }
  ) {
    const userId = this.rc.requireUuidUserId();

    const originalTransactionId = (body?.original_transaction_id || '').trim();
    const transactionId = (body?.transaction_id || '').trim();
    const productId = (body?.product_id || '').trim();
    const providerSubscriptionId = originalTransactionId || transactionId;
    if (!providerSubscriptionId) {
      throw new HttpException({ ok: false, reason: 'provider_subscription_id_required' }, HttpStatus.BAD_REQUEST);
    }

    const eventId =
      (body?.event_id || '').trim() ||
      `apple-verify:${providerSubscriptionId}:${(body?.event_type || 'manual_verify').trim() || 'manual_verify'}`;
    const environment = ((body?.environment || 'sandbox') as string).toLowerCase() === 'production' ? 'production' : 'sandbox';
    const statusIn = ((body?.status || 'active') as string).toLowerCase();
    const allowed = new Set(['trialing', 'active', 'past_due', 'canceled', 'expired']);
    const status = allowed.has(statusIn) ? statusIn : 'active';
    const now = new Date();
    const periodStart = body?.current_period_start ? new Date(body.current_period_start) : now;
    const periodEnd = body?.current_period_end ? new Date(body.current_period_end) : new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000);
    const cancelAtPeriodEnd = body?.cancel_at_period_end === true;
    const autoRenew = body?.auto_renew ?? !cancelAtPeriodEnd;

    let mappedPlan: { id: string; code: string } | null = null;
    if (productId) {
      const planRes = await this.db.query<{ id: string; code: string }>(
        `select sp.id, sp.code
           from subscription_plan_provider_products ppp
           join subscription_plans sp on sp.id = ppp.plan_id
          where ppp.is_active
            and sp.is_active
            and ppp.provider = 'apple'
            and ppp.provider_product_id = $1
          limit 1`,
        [productId]
      );
      mappedPlan = planRes.rows[0] || null;
    }

    const txResult = await this.db.runInTx(async (q) => {
      await q(
        `insert into apple_subscription_events (
           id,
           event_id,
           event_type,
           environment,
           original_transaction_id,
           transaction_id,
           app_account_token,
           product_id,
           signed_payload,
           payload,
           processed_at,
           created_at
         ) values (
           gen_random_uuid(),
           $1,
           $2,
           $3,
           nullif($4,''),
           nullif($5,''),
           nullif($6,'')::uuid,
           nullif($7,''),
           nullif($8,''),
           $9::jsonb,
           now(),
           now()
         )
         on conflict (event_id) do nothing`,
        [
          eventId,
          (body?.event_type || 'manual_verify').trim() || 'manual_verify',
          environment,
          originalTransactionId,
          transactionId,
          body?.app_account_token || '',
          productId,
          body?.signed_payload || '',
          body?.payload && typeof body.payload === 'object' ? JSON.stringify(body.payload) : null,
        ]
      );

      if (!mappedPlan?.id) {
        return { upserted: false, reason: 'plan_mapping_missing' };
      }

      const updateRes = await q<{ id: string }>(
        `update user_subscriptions
            set plan_id = $2::uuid,
                status = $3,
                current_period_start = $4::timestamptz,
                current_period_end = $5::timestamptz,
                cancel_at_period_end = $6,
                auto_renew = $7,
                provider = 'apple',
                provider_subscription_id = $1,
                provider_customer_id = nullif($8,''),
                updated_at = now()
          where user_id = auth.uid()
            and provider = 'apple'
            and provider_subscription_id = $1
          returning id`,
        [
          providerSubscriptionId,
          mappedPlan.id,
          status,
          periodStart.toISOString(),
          periodEnd.toISOString(),
          cancelAtPeriodEnd,
          autoRenew,
          body?.app_account_token || '',
        ]
      );
      if (updateRes.rows[0]) {
        return { upserted: true, mode: 'updated', subscriptionId: updateRes.rows[0].id };
      }

      const insertRes = await q<{ id: string }>(
        `insert into user_subscriptions (
           id,
           user_id,
           plan_id,
           status,
           started_at,
           current_period_start,
           current_period_end,
           cancel_at_period_end,
           auto_renew,
           provider,
           provider_subscription_id,
           provider_customer_id,
           created_at,
           updated_at
         ) values (
           gen_random_uuid(),
           auth.uid(),
           $1::uuid,
           $2,
           now(),
           $3::timestamptz,
           $4::timestamptz,
           $5,
           $6,
           'apple',
           $7,
           nullif($8,''),
           now(),
           now()
         )
         returning id`,
        [
          mappedPlan.id,
          status,
          periodStart.toISOString(),
          periodEnd.toISOString(),
          cancelAtPeriodEnd,
          autoRenew,
          providerSubscriptionId,
          body?.app_account_token || '',
        ]
      );
      return { upserted: true, mode: 'inserted', subscriptionId: insertRes.rows[0]?.id || null };
    });

    return {
      ok: true,
      provider: 'apple',
      environment,
      validation: 'pending_apple_server_validation',
      event_id: eventId,
      product_id: productId || null,
      mapped_plan_code: mappedPlan?.code || null,
      provider_subscription_id: providerSubscriptionId,
      result: txResult,
    };
  }


  // New Stripe Checkout Session endpoint enforcing metadata.user_id
  @Post('stripe/checkout')
  async stripeCheckout(@Body() body: { plan_code?: string; success_url?: string; cancel_url?: string }) {
    const planCode = (body?.plan_code || '').trim();
    if (!planCode) throw new HttpException({ ok: false, reason: 'plan_code_required' }, HttpStatus.BAD_REQUEST);
    const userId = this.rc.requireUuidUserId();
    // Determine billing period + currency from plan row (avoid hardcoded currency)
    const planMeta = await this.db.query<any>(
      `select id, code, currency, billing_period
         from subscription_plans
        where is_active and lower(code)=lower($1)
        limit 1`,
      [planCode]
    );
    if (!planMeta.rows[0]) throw new HttpException({ ok: false, reason: 'plan_not_found', plan: planCode }, HttpStatus.BAD_REQUEST);
    const billingPeriod = (planMeta.rows[0].billing_period || 'month').toLowerCase();
    const planCurrency = (planMeta.rows[0].currency || 'usd').toLowerCase();
    // Fetch price from DB (flexible schema) using actual plan currency & period. Fallback to legacy env mapping if absent.
    const priceEntry = await this.prices.getActivePrice(planCode, billingPeriod, planCurrency);
    const priceId = priceEntry.stripePriceId;
    if (!priceId) throw new HttpException({ ok: false, reason: 'price_id_missing_for_plan', plan: planCode, currency: planCurrency, billing_period: billingPeriod }, HttpStatus.BAD_REQUEST);
    const sk = process.env.STRIPE_SECRET_KEY || '';
    if (!sk) throw new HttpException({ ok: false, reason: 'stripe_secret_missing' }, HttpStatus.INTERNAL_SERVER_ERROR);
    const Stripe = require('stripe');
    const stripe = new Stripe(sk, { apiVersion: '2024-06-20' });
    const successUrl = body?.success_url || process.env.CHECKOUT_SUCCESS_URL || 'http://localhost:3000/checkout/success';
    const cancelUrl = body?.cancel_url || process.env.CHECKOUT_CANCEL_URL || 'http://localhost:3000/checkout/cancel';
    const session = await stripe.checkout.sessions.create({
      mode: 'subscription',
      line_items: [{ price: priceId, quantity: 1 }],
      success_url: successUrl + '?session_id={CHECKOUT_SESSION_ID}',
      cancel_url: cancelUrl,
      metadata: { user_id: userId },
      subscription_data: { metadata: { user_id: userId } }
      // Note: customer_creation is only valid in payment mode; removed for subscription mode.
    });
    return { ok: true, session_id: session.id, url: session.url, plan_code: planCode };
  }

  // Transactional auth debug: confirm auth.uid() inside runInTx matches interceptor claims
  @Get('debug-auth-tx')
  async debugAuthTx(){
    const data = await this.db.runInTx(async (q) => {
      const uidRows = await q<{ uid: string }>(`select auth.uid()::text as uid`);
      return { uid: uidRows.rows[0]?.uid || null, claims: this.rc.claims || null };
    });
    return { ok: true, inTx: true, uid: (data as any).uid, claims: (data as any).claims };
  }
  // mapPlanToPrice removed in favor of PriceService + DB mapping.

  // Temporary debug endpoint (dev): exposes decoded claims and auth.uid() resolution
  @Get('debug-auth')
  async debugAuth() {
    try {
      const data = await this.db.runInTx(async (q) => {
        const uidRow = await q(`select auth.uid()::text as uid`);
        return { uid: uidRow.rows[0]?.uid || null };
      });
      return { ok: true, claims: this.rc.claims || null, authUid: data.uid };
    } catch (e: any) {
      return { ok: false, error: e?.message || String(e), claims: this.rc.claims || null };
    }
  }

  // Lightweight DB status (no transaction) for connectivity diagnostics
  @Get('db-status')
  async dbStatus(){
    try {
      const status = this.db.status;
      // Attempt simple probe if pool exists
      let probe: string | null = null;
      if (!status.stub) {
        try {
          await this.db.query('select 1 as ok');
          probe = 'ok';
        } catch (e: any){
          probe = 'error:' + (e?.message || String(e));
        }
      }
      return { ok: true, status, probe };
    } catch (e: any){
      return { ok: false, error: e?.message || String(e) };
    }
  }

  // Debug: inspect active view vs underlying table
  @Get('debug-active')
  async debugActive(){
    try {
      const result = await this.db.runInTx(async (q) => {
        const uidRows = await q<{ uid: string }>(`select auth.uid()::text as uid`);
        const uid = uidRows.rows[0]?.uid;
        if (!uid) return { uid: null, view: [], subs: [] };
        const viewRows = await q<any>(`select id, plan_id, status, current_period_start, current_period_end, cancel_at_period_end from v_active_user_subscriptions where user_id = auth.uid() order by current_period_end desc`);
        const subRows = await q<any>(`select id, plan_id, status, current_period_start, current_period_end, cancel_at_period_end from user_subscriptions where user_id = auth.uid() order by current_period_end desc`);
        return { uid, viewRows, subRows };
      });
      return { ok: true, uid: (result as any).uid, view: (result as any).viewRows, subs: (result as any).subRows };
    } catch (e: any){
      return { ok: false, error: e?.message || String(e) };
    }
  }

  @Post('portal')
  async portal() {
    const userId = this.rc.requireUuidUserId();
    const sk = process.env.STRIPE_SECRET_KEY || '';
    if (!sk) {
      throw new HttpException({ ok: false, reason: 'stripe_secret_missing' }, HttpStatus.INTERNAL_SERVER_ERROR);
    }
    if (this.db.isStub) {
      throw new HttpException({ ok: false, reason: 'db_unavailable' }, HttpStatus.SERVICE_UNAVAILABLE);
    }

    const customerId = await this.db.runInTx(async (q) => {
      const { rows } = await q<{ stripe_customer_id: string | null }>(
        `with latest_stripe_subscription as (
           select provider_customer_id
             from user_subscriptions
            where user_id = auth.uid()
              and provider = 'stripe'
              and provider_customer_id is not null
            order by updated_at desc nulls last
            limit 1
         )
         select coalesce(bp.stripe_customer_id, sc.stripe_customer_id, lss.provider_customer_id) as stripe_customer_id
           from (select auth.uid() as user_id) current_user
           left join billing_profiles bp on bp.user_id = current_user.user_id
           left join stripe_customers sc on sc.user_id = current_user.user_id
           left join latest_stripe_subscription lss on true
          limit 1`
      );
      return rows[0]?.stripe_customer_id?.trim() || null;
    });

    if (!customerId) {
      throw new HttpException({ ok: false, reason: 'no_stripe_customer', userId }, HttpStatus.BAD_REQUEST);
    }

    try {
      const Stripe = require('stripe');
      const stripe = new Stripe(sk, { apiVersion: '2024-06-20' });
      const returnUrl =
        process.env.STRIPE_PORTAL_RETURN_URL ||
        process.env.CHECKOUT_CANCEL_URL ||
        'http://localhost:3000/account/billing';
      const session = await stripe.billingPortal.sessions.create({
        customer: customerId,
        return_url: returnUrl,
      });

      return { ok: true, url: session.url };
    } catch (e: any) {
      throw new HttpException({ ok: false, reason: 'portal_failed', error: e?.message || String(e) }, HttpStatus.BAD_REQUEST);
    }
  }

  // ---- Overage (one-off purchase when quota exhausted) ----
  // Creates a one-off Stripe Checkout Session for overage unit (chat/video).
  @Post('overage/checkout')
  async overageCheckout(@Body() body: { code: string; quantity?: number; original_session_id?: string; currency?: string; success_url?: string; cancel_url?: string }) {
    const code = (body?.code || '').trim();
    if (!code) throw new HttpException({ ok: false, reason: 'code_required' }, HttpStatus.BAD_REQUEST);
    const quantity = body?.quantity && body.quantity > 0 ? Math.floor(body.quantity) : 1;
    const currency = (body?.currency || 'mxn').toLowerCase();
    const userId = this.rc.requireUuidUserId();
    // Lookup catalog item
    const itemRow = await this.db.query<any>(
      `select id, code, name, currency, amount_cents, metadata from overage_items where is_active and lower(code)=lower($1) and lower(currency)=lower($2) limit 1`,
      [code, currency]
    );
    if (!itemRow.rows[0]) throw new HttpException({ ok: false, reason: 'item_not_found', code, currency }, HttpStatus.BAD_REQUEST);
    const item = itemRow.rows[0];
    const sk = process.env.STRIPE_SECRET_KEY || '';
    if (!sk) throw new HttpException({ ok: false, reason: 'stripe_secret_missing' }, HttpStatus.INTERNAL_SERVER_ERROR);
    const Stripe = require('stripe');
    const stripe = new Stripe(sk, { apiVersion: '2024-06-20' });
    const successUrl = body?.success_url || process.env.CHECKOUT_SUCCESS_URL || 'http://localhost:3000/overage/success';
    const cancelUrl = body?.cancel_url || process.env.CHECKOUT_CANCEL_URL || 'http://localhost:3000/overage/cancel';
    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      line_items: [{
        price_data: {
          currency,
          product_data: { name: item.name },
          unit_amount: item.amount_cents,
        },
        quantity,
      }],
      success_url: successUrl + '?session_id={CHECKOUT_SESSION_ID}',
      cancel_url: cancelUrl,
      metadata: { user_id: userId, overage_item_code: code, original_session_id: body?.original_session_id || '' },
    });
    // Persist purchase
    const amountTotal = item.amount_cents * quantity;
    await this.db.query(
      `insert into overage_purchases (user_id, overage_item_id, status, stripe_checkout_session_id, quantity, amount_cents_total, currency, original_session_id)
       values ($1::uuid, $2::uuid, 'checkout_created', $3, $4, $5, $6, nullif($7,'')::uuid)
       on conflict (stripe_checkout_session_id) do nothing`,
      [userId, item.id, session.id, quantity, amountTotal, currency, body?.original_session_id || '']
    );
    return { ok: true, session_id: session.id, url: session.url, code, quantity, currency };
  }

  // Confirms overage purchase and records a consumption (even if quota exhausted).
  @Post('overage/consume')
  async overageConsume(@Body() body: { code: string; original_session_id?: string }) {
    try {
      if (this.db.isStub) return { ok: true, stub: true } as any;
      const code = (body?.code || '').trim();
      if (!code) throw new HttpException({ ok: false, reason: 'code_required' }, HttpStatus.BAD_REQUEST);
      // Lookup item (for type mapping)
      const itemRow = await this.db.query<any>(
        `select id, metadata from overage_items where is_active and lower(code)=lower($1) limit 1`,
        [code]
      );
      if (!itemRow.rows[0]) throw new HttpException({ ok: false, reason: 'item_not_found' }, HttpStatus.BAD_REQUEST);
      const itemId = itemRow.rows[0].id;
      const meta = itemRow.rows[0].metadata || {};
      const t = (meta.type || '').toString() || (code.includes('video') ? 'video' : code.includes('chat') ? 'chat' : code.includes('sms') ? 'sms' : 'emergency');
      const sessionId = (body?.original_session_id || '').trim();
      const res = await this.db.runInTx(async (q) => {
        // Active subscription required to attach consumption
        const { rows: subs } = await q<{ id: string }>(
          `select id
             from user_subscriptions
            where user_id = auth.uid()
              and status = 'active'
              and coalesce(current_period_end, now()) > now()
            order by current_period_end desc nulls last
            limit 1 for update`
        );
        if (!subs[0]) return { noSub: true } as any;
        const subId = subs[0].id;

        // Attempt to find an unconsumed paid purchase for this item & optional session binding
        const { rows: purchaseRows } = await q<{ id: string }>(
          `select p.id
             from overage_purchases p
             left join entitlement_consumptions ec on ec.overage_purchase_id = p.id
            where p.user_id = auth.uid()
              and p.overage_item_id = $1::uuid
              and p.status = 'paid'
              and ec.id is null
              and ($2::uuid is null or p.original_session_id = $2::uuid)
            order by p.created_at asc
            limit 1 for update`,
          [itemId, sessionId || null]
        );
        if (purchaseRows[0]) {
          const purchaseId = purchaseRows[0].id;
          // Insert consumption referencing purchase
          const { rows: cons } = await q<{ id: string }>(
            `insert into entitlement_consumptions (id, subscription_id, session_id, consumption_type, amount, source, overage_purchase_id, created_at)
             values (gen_random_uuid(), $1::uuid, nullif($2,'')::uuid, $3::text, 1, 'overage', $4::uuid, now())
             returning id`,
            [subId, sessionId || '', t, purchaseId]
          );
          // Mark purchase consumed
          await q(`update overage_purchases set status='consumed', updated_at=now() where id=$1`, [purchaseId]);
          return { mode: 'purchase', purchaseId, consumptionId: cons[0]?.id, subId };
        }

        // Fallback: draw from credit bucket
        const { rows: creditRows } = await q<{ id: string; remaining_units: number }>(
          `select oc.id, oc.remaining_units
             from overage_credits oc
             join overage_items oi on oi.id = oc.overage_item_id
            where oc.user_id = auth.uid()
              and oc.overage_item_id = $1::uuid
              and oc.remaining_units > 0
            limit 1 for update`,
          [itemId]
        );
        if (creditRows[0]) {
          const creditId = creditRows[0].id;
          const { rows: upd } = await q<{ remaining_units: number }>(
            `update overage_credits
                set remaining_units = remaining_units - 1,
                    updated_at = now()
              where id = $1
                and remaining_units > 0
              returning remaining_units`,
            [creditId]
          );
          if (upd[0]) {
            const remaining = upd[0].remaining_units;
            const { rows: cons } = await q<{ id: string }>(
              `insert into entitlement_consumptions (id, subscription_id, session_id, consumption_type, amount, source, created_at)
               values (gen_random_uuid(), $1::uuid, nullif($2,'')::uuid, $3::text, 1, 'credit', now())
               returning id`,
              [subId, sessionId || '', t]
            );
            return { mode: 'credit', creditRemaining: remaining, consumptionId: cons[0]?.id, subId };
          }
        }

        return { none: true } as any;
      });
      if ((res as any).noSub) return { ok: false, reason: 'no_active_subscription' };
      if ((res as any).none) return { ok: false, reason: 'no_purchase_or_credit_available' };
      if ((res as any).mode === 'purchase') {
        return { ok: true, mode: 'purchase', purchase_id: (res as any).purchaseId, consumption_id: (res as any).consumptionId };
      }
      if ((res as any).mode === 'credit') {
        return { ok: true, mode: 'credit', remaining_units: (res as any).creditRemaining, consumption_id: (res as any).consumptionId };
      }
      return { ok: false, reason: 'unexpected_state' };
    } catch (e: any) {
      throw new HttpException(e?.message || 'overage_consume_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get('overage/items')
  async listOverageItems() {
    const { rows } = await this.db.query<any>(`select code, name, description, currency, amount_cents, is_active from overage_items where is_active order by name asc`);
    return { ok: true, items: rows };
  }

  @Get('overage/credits')
  async listOverageCredits() {
    const rows = await this.db.runInTx(async (q) => {
      const { rows } = await q<any>(
        `select oi.code, oc.remaining_units, oc.expires_at
           from overage_credits oc
           join overage_items oi on oi.id = oc.overage_item_id
          where oc.user_id = auth.uid()`
      );
      return rows;
    });
    return { ok: true, credits: rows };
  }

  // List overage purchases for current user
  @Get('admin/overage/purchases')
  async listOveragePurchases(@Req() req: any) {
    try {
      const secret = process.env.ADMIN_PRICING_SYNC_SECRET || process.env.ADMIN_SECRET || '';
      const hdr = req?.headers?.['x-admin-secret'];
      if (!secret || hdr !== secret) return { ok: false, reason: 'admin_forbidden' };
      if (this.db.isStub) return { ok: true, stub: true, purchases: [] } as any;
      const rows = await this.db.runInTx(async (q) => {
        const { rows } = await q<any>(
          `select p.id, oi.code, p.status, p.quantity, p.amount_cents_total, p.currency, p.original_session_id, p.created_at, p.updated_at
             from overage_purchases p
             join overage_items oi on oi.id = p.overage_item_id
            where p.user_id = auth.uid()
            order by p.created_at desc`
        );
        return rows;
      });
      return { ok: true, purchases: rows };
    } catch (e: any) {
      throw new HttpException(e?.message || 'overage_purchases_list_failed', HttpStatus.BAD_REQUEST);
    }
  }

  // List overage/credit consumptions for current user (sources overage|credit)
  @Get('admin/overage/consumptions')
  async listOverageConsumptions(@Req() req: any) {
    try {
      const secret = process.env.ADMIN_PRICING_SYNC_SECRET || process.env.ADMIN_SECRET || '';
      const hdr = req?.headers?.['x-admin-secret'];
      if (!secret || hdr !== secret) return { ok: false, reason: 'admin_forbidden' };
      if (this.db.isStub) return { ok: true, stub: true, consumptions: [] } as any;
      const rows = await this.db.runInTx(async (q) => {
        const { rows } = await q<any>(
          `select ec.id, ec.source, ec.session_id, ec.consumption_type, ec.amount, ec.created_at, ec.overage_purchase_id
             from entitlement_consumptions ec
             join user_subscriptions us on us.id = ec.subscription_id
            where us.user_id = auth.uid()
              and ec.source in ('overage','credit')
            order by ec.created_at desc`
        );
        return rows;
      });
      return { ok: true, consumptions: rows };
    } catch (e: any) {
      throw new HttpException(e?.message || 'overage_consumptions_list_failed', HttpStatus.BAD_REQUEST);
    }
  }

  // Mark a purchase paid manually (admin or dev use) and optionally auto-consume if session-bound.
  @Post('admin/overage/mark-paid')
  async markOveragePaid(@Body() body: { purchase_id?: string; force_consume?: boolean }, @Req() req: any) {
    try {
      const secret = process.env.ADMIN_PRICING_SYNC_SECRET || process.env.ADMIN_SECRET || '';
      const hdr = req?.headers?.['x-admin-secret'];
      if (!secret || hdr !== secret) return { ok: false, reason: 'admin_forbidden' };
      if (this.db.isStub) return { ok: true, stub: true } as any;
      const pid = (body?.purchase_id || '').trim();
      if (!pid) return { ok: false, reason: 'purchase_id_required' };
      const row = await this.db.runInTx(async (q) => {
        // Lock purchase
        const { rows: purchaseRows } = await q<any>(
          `select p.id, p.user_id, p.status, p.original_session_id, p.overage_item_id, p.quantity
             from overage_purchases p
            where p.id = $1::uuid and p.user_id = auth.uid()
            limit 1 for update`, [pid]
        );
        if (!purchaseRows[0]) return { notFound: true } as any;
        const purchase = purchaseRows[0];
        if (purchase.status === 'paid' || purchase.status === 'consumed') return { already: true, purchase } as any;
        // Transition to paid
        await q(`update overage_purchases set status='paid', updated_at=now() where id=$1`, [pid]);
        // Auto credit if not session-bound
        if (!purchase.original_session_id) {
          // Credit bucket increment
            const { rows: creditItemRow } = await q<any>(`select id, code from overage_items where id=$1`, [purchase.overage_item_id]);
            const itemCode = creditItemRow[0]?.code;
            if (itemCode) {
              // Find or create credits row
              const { rows: existingCredits } = await q<any>(
                `select id from overage_credits where user_id = auth.uid() and overage_item_id=$1 limit 1 for update`,
                [purchase.overage_item_id]
              );
              if (existingCredits[0]) {
                await q(`update overage_credits set remaining_units = remaining_units + $2, updated_at=now() where id=$1`, [existingCredits[0].id, purchase.quantity]);
              } else {
                await q(`insert into overage_credits (id, user_id, overage_item_id, remaining_units, created_at, updated_at) values (gen_random_uuid(), auth.uid(), $1, $2, now(), now())`, [purchase.overage_item_id, purchase.quantity]);
              }
              return { mode: 'credited', purchase_id: purchase.id, quantity: purchase.quantity } as any;
            }
        }
        // Session-bound auto consume if requested and original_session_id present
        if (purchase.original_session_id && body?.force_consume) {
          // Need active subscription id
          const { rows: subs } = await q<{ id: string }>(`select id from v_active_user_subscriptions where user_id=auth.uid() limit 1`);
          const subId = subs[0]?.id;
          if (!subId) return { noSub: true } as any;
          // Map item type
          const { rows: itemMeta } = await q<any>(`select metadata from overage_items where id=$1`, [purchase.overage_item_id]);
          const meta = itemMeta[0]?.metadata || {};
          const t = (meta.type || '').toString() || (itemMeta[0] && itemMeta[0].metadata?.type) || 'chat';
          const { rows: cons } = await q<{ id: string }>(
            `insert into entitlement_consumptions (id, subscription_id, session_id, consumption_type, amount, source, overage_purchase_id, created_at)
             values (gen_random_uuid(), $1::uuid, $2::uuid, $3::text, 1, 'overage', $4::uuid, now()) returning id`,
            [subId, purchase.original_session_id, t, purchase.id]
          );
          await q(`update overage_purchases set status='consumed', updated_at=now() where id=$1`, [purchase.id]);
          return { mode: 'consumed', purchase_id: purchase.id, consumption_id: cons[0]?.id } as any;
        }
        return { mode: 'paid', purchase_id: purchase.id } as any;
      });
      if ((row as any).notFound) return { ok: false, reason: 'purchase_not_found' };
      if ((row as any).already) return { ok: true, already: true, purchase: (row as any).purchase };
      if ((row as any).noSub) return { ok: false, reason: 'no_active_subscription' };
      return { ok: true, ...row };
    } catch (e: any) {
      throw new HttpException(e?.message || 'overage_mark_paid_failed', HttpStatus.BAD_REQUEST);
    }
  }

  // Mark purchase refunded and reverse credits if still in paid state (not yet consumed).
  @Post('admin/overage/mark-refunded')
  async markOverageRefunded(@Body() body: { purchase_id?: string }, @Req() req: any) {
    try {
      const secret = process.env.ADMIN_PRICING_SYNC_SECRET || process.env.ADMIN_SECRET || '';
      const hdr = req?.headers?.['x-admin-secret'];
      if (!secret || hdr !== secret) return { ok: false, reason: 'admin_forbidden' };
      if (this.db.isStub) return { ok: true, stub: true } as any;
      const pid = (body?.purchase_id || '').trim();
      if (!pid) return { ok: false, reason: 'purchase_id_required' };
      const row = await this.db.runInTx(async (q) => {
        const { rows: purchaseRows } = await q<any>(
          `select p.id, p.status, p.quantity, p.original_session_id, p.overage_item_id
             from overage_purchases p
            where p.id=$1::uuid and p.user_id=auth.uid()
            limit 1 for update`, [pid]
        );
        if (!purchaseRows[0]) return { notFound: true } as any;
        const purchase = purchaseRows[0];
        const prevStatus = purchase.status;
        // Reverse credits only if it was a paid (not consumed) unit purchase (no original_session_id)
        let creditsReversed = 0;
        if (prevStatus === 'paid' && !purchase.original_session_id) {
          // decrement credits bucket
          const { rows: creditRow } = await q<any>(
            `select id, remaining_units from overage_credits where user_id=auth.uid() and overage_item_id=$1 limit 1 for update`,
            [purchase.overage_item_id]
          );
            if (creditRow[0]) {
              const toRemove = Math.min(creditRow[0].remaining_units, purchase.quantity);
              if (toRemove > 0) {
                await q(`update overage_credits set remaining_units = remaining_units - $2, updated_at=now() where id=$1`, [creditRow[0].id, toRemove]);
                creditsReversed = toRemove;
              }
            }
        }
        await q(`update overage_purchases set status='refunded', updated_at=now() where id=$1`, [purchase.id]);
        return { purchase_id: purchase.id, previous_status: prevStatus, credits_reversed: creditsReversed };
      });
      if ((row as any).notFound) return { ok: false, reason: 'purchase_not_found' };
      return { ok: true, ...row };
    } catch (e: any) {
      throw new HttpException(e?.message || 'overage_mark_refunded_failed', HttpStatus.BAD_REQUEST);
    }
  }

  // Adjust credit units manually (delta can be positive to grant or negative to revoke)
  @Post('admin/overage/adjust-credits')
  async adjustCredits(@Body() body: { code?: string; delta?: number; expires_at?: string }, @Req() req: any) {
    try {
      const secret = process.env.ADMIN_PRICING_SYNC_SECRET || process.env.ADMIN_SECRET || '';
      const hdr = req?.headers?.['x-admin-secret'];
      if (!secret || hdr !== secret) return { ok: false, reason: 'admin_forbidden' };
      if (this.db.isStub) return { ok: true, stub: true } as any;
      const code = (body?.code || '').trim();
      const deltaRaw = body?.delta;
      if (!code) return { ok: false, reason: 'code_required' };
      if (typeof deltaRaw !== 'number' || !Number.isFinite(deltaRaw) || deltaRaw === 0) return { ok: false, reason: 'delta_required_nonzero' };
      const delta = Math.trunc(deltaRaw);
      const row = await this.db.runInTx(async (q) => {
        const { rows: itemRows } = await q<any>(`select id from overage_items where is_active and lower(code)=lower($1) limit 1`, [code]);
        if (!itemRows[0]) return { itemNotFound: true } as any;
        const itemId = itemRows[0].id;
        // Lock existing credit row
        const { rows: creditRows } = await q<any>(
          `select id, remaining_units from overage_credits where user_id = auth.uid() and overage_item_id=$1 limit 1 for update`,
          [itemId]
        );
        if (delta > 0) {
          if (creditRows[0]) {
            const { rows: upd } = await q<any>(
              `update overage_credits set remaining_units = remaining_units + $2, expires_at = coalesce($3::timestamptz, expires_at), updated_at=now()
               where id=$1 returning remaining_units`,
              [creditRows[0].id, delta, body?.expires_at || null]
            );
            return { mode: 'increment', remaining: upd[0].remaining_units };
          } else {
            const { rows: ins } = await q<any>(
              `insert into overage_credits (id, user_id, overage_item_id, remaining_units, expires_at, created_at, updated_at)
               values (gen_random_uuid(), auth.uid(), $1, $2, $3::timestamptz, now(), now()) returning remaining_units`,
              [itemId, delta, body?.expires_at || null]
            );
            return { mode: 'create', remaining: ins[0].remaining_units };
          }
        } else {
          if (!creditRows[0]) return { noCredits: true } as any;
          const abs = Math.min(creditRows[0].remaining_units, Math.abs(delta));
          if (abs === 0) return { nothingToRemove: true } as any;
          const { rows: upd } = await q<any>(
            `update overage_credits set remaining_units = remaining_units - $2, updated_at=now() where id=$1 returning remaining_units`,
            [creditRows[0].id, abs]
          );
          return { mode: 'decrement', removed: abs, remaining: upd[0].remaining_units };
        }
      });
      if ((row as any).itemNotFound) return { ok: false, reason: 'item_not_found' };
      if ((row as any).noCredits) return { ok: false, reason: 'no_existing_credit_row' };
      if ((row as any).nothingToRemove) return { ok: false, reason: 'nothing_to_remove' };
      return { ok: true, ...row };
    } catch (e: any) {
      throw new HttpException(e?.message || 'overage_adjust_credits_failed', HttpStatus.BAD_REQUEST);
    }
  }

  // Admin: CRUD for overage items (create/update/deactivate)
  @Post('admin/overage/items')
  async upsertOverageItem(@Body() body: { id?: string; code?: string; name?: string; description?: string; currency?: string; amount_cents?: number; is_active?: boolean; metadata?: any }, @Req() req: any) {
    try {
      const secret = process.env.ADMIN_PRICING_SYNC_SECRET || process.env.ADMIN_SECRET || '';
      const hdr = req?.headers?.['x-admin-secret'];
      if (!secret || hdr !== secret) return { ok: false, reason: 'admin_forbidden' };
      if (this.db.isStub) return { ok: true, stub: true } as any;
      const { id, code, name, description, currency, amount_cents, is_active, metadata } = body || {} as any;
      if (!code || !name || !currency || typeof amount_cents !== 'number') return { ok: false, reason: 'invalid_item_payload' };
      const res = await this.db.runInTx(async (q) => {
        const { rows: existing } = await q<any>(`select id from overage_items where code=$1 limit 1 for update`, [code]);
        if (existing[0]) {
          await q(`update overage_items set name=coalesce($2,name), description=coalesce($3,description), currency=coalesce($4,currency), amount_cents=coalesce($5,amount_cents), is_active=coalesce($6,is_active), metadata=coalesce($7,metadata), updated_at=now() where id=$1`, [existing[0].id, name, description, currency, amount_cents, is_active, metadata]);
          return { mode: 'updated', id: existing[0].id } as any;
        } else {
          const newId = (await q<any>(`insert into overage_items (id, code, name, description, currency, amount_cents, is_active, metadata, created_at, updated_at) values (gen_random_uuid(), $1, $2, $3, $4, $5, coalesce($6,true), $7, now(), now()) returning id`, [code, name, description, currency, amount_cents, is_active, metadata])).rows[0].id;
          return { mode: 'created', id: newId } as any;
        }
      });
      return { ok: true, ...res };
    } catch (e: any) {
      throw new HttpException(e?.message || 'overage_items_upsert_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get('admin/overage/items')
  async listOverageItemsAdmin(@Req() req: any) {
    try {
      const secret = process.env.ADMIN_PRICING_SYNC_SECRET || process.env.ADMIN_SECRET || '';
      const hdr = req?.headers?.['x-admin-secret'];
      if (!secret || hdr !== secret) return { ok: false, reason: 'admin_forbidden' };
      if (this.db.isStub) return { ok: true, stub: true, items: [] } as any;
      const rows = await this.db.runInTx(async (q) => {
        const { rows } = await q<any>(`select id, code, name, description, currency, amount_cents, is_active, metadata, created_at, updated_at from overage_items order by is_active desc, code asc`);
        return rows;
      });
      return { ok: true, items: rows };
    } catch (e: any) {
      throw new HttpException(e?.message || 'overage_items_list_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('cancel')
  async cancel(@Body() body: { immediate?: boolean }) {
    try {
      if (this.db.isStub) return { ok: true, stub: true } as any;
      const row = await this.db.runInTx(async (q) => {
        // Removed FOR UPDATE to avoid RLS blocking row visibility when UPDATE policy not granted.
        const active = await q(`select id, status, current_period_end from v_active_user_subscriptions where user_id = auth.uid() limit 1`);
        if (!active.rows[0]) return { notFound: true } as any;
        if (body?.immediate) {
          const upd = await q(
            `update user_subscriptions set status='canceled', cancel_at_period_end=true, current_period_end = now()
             where id = $1 returning id, status, current_period_end, cancel_at_period_end`,
            [active.rows[0].id]
          );
          return { sub: upd.rows[0], immediate: true };
        }
        const upd = await q(
          `update user_subscriptions set cancel_at_period_end=true where id = $1 returning id, status, current_period_end, cancel_at_period_end`,
          [active.rows[0].id]
        );
        return { sub: upd.rows[0], immediate: false };
      });
      if ((row as any).notFound) return { ok: false, reason: 'no_active_subscription' };
      return { ok: true, action: 'cancel', immediate: (row as any).immediate, subscription: (row as any).sub };
    } catch (e: any) {
      throw new (require('@nestjs/common').HttpException)({ ok: false, reason: 'cancel_failed', error: e?.message }, 400);
    }
  }

  @Post('resume')
  async resume() {
    try {
      if (this.db.isStub) return { ok: true, stub: true } as any;
      const row = await this.db.runInTx(async (q) => {
        // Query underlying table directly so scheduled cancellations are still visible.
        const { rows: subs } = await q(
          `select id, status, cancel_at_period_end
             from user_subscriptions
            where user_id = auth.uid()
              and status = 'active'
            order by current_period_end desc
            limit 1`
        );
        if (!subs[0]) return { notFound: true } as any;
        const sub = subs[0];
        if (!sub.cancel_at_period_end) return { notCanceled: true } as any;
        const { rows: upd } = await q(
          `update user_subscriptions
              set cancel_at_period_end = false,
                  updated_at = now()
            where id = $1
            returning id, status, cancel_at_period_end`,
          [sub.id]
        );
        return { sub: upd[0] };
      });
      if ((row as any).notFound) return { ok: false, reason: 'no_active_subscription' };
      if ((row as any).notCanceled) return { ok: false, reason: 'cannot_resume_not_canceled' };
      return { ok: true, action: 'resume', subscription: (row as any).sub };
    } catch (e: any) {
      throw new (require('@nestjs/common').HttpException)({ ok: false, reason: 'resume_failed', error: e?.message }, 400);
    }
  }

  @Post('change-plan')
  async changePlan(@Body() body: { code?: string; seats?: number }) {
    try {
      if (this.db.isStub) return { ok: true, stub: true } as any;
      const code = (body?.code || '').trim();
      if (!code) return { ok: false, reason: 'validation_error', details: 'code required' };
      const row = await this.db.runInTx(async (q) => {
        // Removed FOR UPDATE to prevent RLS filtering when UPDATE not allowed directly on view.
        const active = await q(`select id, plan_id from v_active_user_subscriptions where user_id = auth.uid() limit 1`);
        if (!active.rows[0]) return { notFound: true } as any;
        const plan = await q(
          `select id, code, included_chats, included_videos, pets_included_default from subscription_plans where is_active and lower(code)=lower($1) limit 1`,
          [code]
        );
        if (!plan.rows[0]) return { planNotFound: true } as any;
        if (plan.rows[0].id === active.rows[0].plan_id) return { samePlan: true } as any;
        const upd = await q(
          `update user_subscriptions set plan_id = $1, pets_included = coalesce($2, pets_included)
             where id = $3 returning id, plan_id`,
          [plan.rows[0].id, body?.seats || plan.rows[0].pets_included_default, active.rows[0].id]
        );
        // Adjust usage included counts for new plan (without reducing consumed counts)
        await q(
          `update subscription_usage set included_chats = $1, included_videos = $2, updated_at = now() where subscription_id = $3`,
          [plan.rows[0].included_chats, plan.rows[0].included_videos, active.rows[0].id]
        );
        return { sub: upd.rows[0], plan: plan.rows[0] };
      });
      if ((row as any).notFound) return { ok: false, reason: 'no_active_subscription' };
      if ((row as any).planNotFound) return { ok: false, reason: 'plan_not_found' };
      if ((row as any).samePlan) return { ok: false, reason: 'change_plan_same_plan' };
      return { ok: true, action: 'change-plan', subscription: (row as any).sub, plan: (row as any).plan };
    } catch (e: any) {
      throw new (require('@nestjs/common').HttpException)({ ok: false, reason: 'change_plan_failed', error: e?.message }, 400);
    }
  }

  @Post('activate-plan')
  async activatePlan(@Body() body: { code?: string; seats?: number }) {
    try {
      if (this.db.isStub) return { ok: true, stub: true, action: 'activate-plan' } as any;
      const code = (body?.code || '').trim();
      if (!code) return { ok: false, reason: 'validation_error', details: 'code required' };

      const row = await this.db.runInTx(async (q) => {
        const stripeManagedActive = await q<any>(
          `select id, provider, status, current_period_end
             from user_subscriptions
            where user_id = auth.uid()
              and provider = 'stripe'
              and status in ('trialing','active')
              and coalesce(current_period_end, now()) > now()
            order by current_period_end desc nulls last
            limit 1`
        );
        if (stripeManagedActive.rows[0]) {
          return {
            stripeManagedActive: true,
            existing: stripeManagedActive.rows[0],
          } as any;
        }

        const plan = await q<any>(
          `select id, code, included_chats, included_videos, pets_included_default, billing_period
             from subscription_plans
            where is_active and lower(code)=lower($1)
            limit 1`,
          [code]
        );
        if (!plan.rows[0]) return { planNotFound: true } as any;

        const active = await q<any>(
          `select id, plan_id, current_period_start, current_period_end
             from user_subscriptions
            where user_id = auth.uid()
              and status in ('trialing','active')
              and coalesce(current_period_end, now()) > now()
            order by current_period_end desc nulls last
            limit 1`
        );

        const planRow = plan.rows[0];
        const seats = body?.seats || planRow.pets_included_default;

        if (active.rows[0]) {
          const subId = active.rows[0].id;
          const upd = await q<any>(
            `update user_subscriptions
                set plan_id = $1,
                    status = 'active',
                    pets_included = coalesce($2, pets_included),
                    provider = coalesce(provider, 'internal'),
                    auto_renew = true,
                    updated_at = now()
              where id = $3
              returning id, plan_id, status, current_period_start, current_period_end, pets_included`,
            [planRow.id, seats, subId]
          );

          await q(
            `insert into subscription_usage (
               id, subscription_id, period_start, period_end,
               included_chats, included_videos,
               consumed_chats, consumed_videos,
               overage_chats, overage_videos,
               updated_at
             ) values (
               gen_random_uuid(), $1, $2, $3,
               $4, $5,
               0, 0,
               0, 0,
               now()
             )
             on conflict (subscription_id, period_start, period_end)
             do update set
               included_chats = EXCLUDED.included_chats,
               included_videos = EXCLUDED.included_videos,
               updated_at = now()`,
            [
              subId,
              upd.rows[0].current_period_start,
              upd.rows[0].current_period_end,
              planRow.included_chats,
              planRow.included_videos,
            ]
          );

          return { mode: 'updated', subscription: upd.rows[0], plan: planRow };
        }

        const ins = await q<any>(
          `insert into user_subscriptions (
             id, user_id, plan_id, status,
             started_at, current_period_start, current_period_end,
             cancel_at_period_end, auto_renew,
             provider, pets_included,
             created_at, updated_at
           ) values (
             gen_random_uuid(), auth.uid(), $1, 'active',
             now(), now(),
             case
               when lower(coalesce($3::text, 'month')) = 'year' then now() + interval '1 year'
               else now() + interval '1 month'
             end,
             false, true,
             'internal', $2,
             now(), now()
           )
           returning id, plan_id, status, current_period_start, current_period_end, pets_included`,
          [planRow.id, seats, planRow.billing_period]
        );

        const sub = ins.rows[0];
        await q(
          `insert into subscription_usage (
             id, subscription_id, period_start, period_end,
             included_chats, included_videos,
             consumed_chats, consumed_videos,
             overage_chats, overage_videos,
             updated_at
           ) values (
             gen_random_uuid(), $1, $2, $3,
             $4, $5,
             0, 0,
             0, 0,
             now()
           )
           on conflict (subscription_id, period_start, period_end)
           do update set
             included_chats = EXCLUDED.included_chats,
             included_videos = EXCLUDED.included_videos,
             updated_at = now()`,
          [
            sub.id,
            sub.current_period_start,
            sub.current_period_end,
            planRow.included_chats,
            planRow.included_videos,
          ]
        );

        return { mode: 'inserted', subscription: sub, plan: planRow };
      });

      if ((row as any).stripeManagedActive) {
        return {
          ok: false,
          reason: 'stripe_subscription_active_use_stripe_flow',
          existing: (row as any).existing,
        };
      }
      if ((row as any).planNotFound) return { ok: false, reason: 'plan_not_found' };
      return {
        ok: true,
        action: 'activate-plan',
        mode: (row as any).mode,
        subscription: (row as any).subscription,
        plan: (row as any).plan,
      };
    } catch (e: any) {
      throw new (require('@nestjs/common').HttpException)({ ok: false, reason: 'activate_plan_failed', error: e?.message }, 400);
    }
  }

  @Post('reserve-chat')
  async reserveChat(@Body() body: { userId: string; sessionId: string }) {
    try {
      if (this.db.isStub) {
        return { ok: true, mode: 'stub', reserved: true, type: 'chat', ...body };
      }
      const result = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `select * from fn_reserve_chat(auth.uid(), trim($1)::uuid)`,
          [body.sessionId]
        );
        return rows[0];
      });
      return { ok: true, result };
    } catch (e: any) {
      throw new HttpException(e?.message || 'reserve_chat_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('reserve-video')
  async reserveVideo(@Body() body: { userId: string; sessionId: string }) {
    try {
      if (this.db.isStub) {
        return { ok: true, mode: 'stub', reserved: true, type: 'video', ...body };
      }
      const result = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `select * from fn_reserve_video(auth.uid(), trim($1)::uuid)`,
          [body.sessionId]
        );
        return rows[0];
      });
      return { ok: true, result };
    } catch (e: any) {
      throw new HttpException(e?.message || 'reserve_video_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('commit')
  async commit(@Body() body: { consumptionId: string }) {
    try {
      if (this.db.isStub) return { ok: true, mode: 'stub', committed: true, ...body };
      const ok = await this.db.runInTx(async (q) => {
        const { rows } = await q(`select fn_commit_consumption(trim($1)::uuid) as ok`, [body.consumptionId]);
        return !!rows[0]?.ok;
      });
      return { ok };
    } catch (e: any) {
      throw new HttpException(e?.message || 'commit_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('release')
  async release(@Body() body: { consumptionId: string }) {
    try {
      if (this.db.isStub) return { ok: true, mode: 'stub', released: true, ...body };
      const ok = await this.db.runInTx(async (q) => {
        const { rows } = await q(`select fn_release_consumption(trim($1)::uuid) as ok`, [body.consumptionId]);
        return !!rows[0]?.ok;
      });
      return { ok };
    } catch (e: any) {
      throw new HttpException(e?.message || 'release_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get('usage')
  async getUsage() {
    try {
      if (this.db.isStub) {
        return { ok: true, mode: 'stub', usage: { included_chats: 2, consumed_chats: 0, included_videos: 1, consumed_videos: 0, overage_chats: 0, overage_videos: 0 } };
      }
      const usage = await this.db.runInTx(async (q) => {
        // Use underlying table to include scheduled-cancel subs until period end
        const { rows: subs } = await q<{ id: string }>(
          `select id
             from user_subscriptions
            where user_id = auth.uid()
              and status = 'active'
              and coalesce(current_period_end, now()) > now()
            order by current_period_end desc nulls last
            limit 1`
        );
        if (!subs[0]) return null;
        const subId = subs[0].id;
        const { rows } = await q<any>(`select * from fn_current_usage(trim($1)::uuid)`, [subId]);
        return rows[0] || null;
      });
      if (!usage) {
        return { ok: false, reason: 'no_active_subscription', message: 'No active subscription. Acquire a plan to access usage.', usage: null };
      }
      return { ok: true, usage };
    } catch (e: any) {
      throw new HttpException(e?.message || 'usage_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get('my')
  async mySubscriptions() {
    try {
      if (this.db.isStub) {
        return { data: [] } as any;
      }
      const rows = await this.db.runInTx(async (q) => {
        const { rows } = await q<any>(
          `select
             s.id as sub_id,
             s.status,
             s.current_period_start,
             s.current_period_end,
             s.cancel_at_period_end,
             s.pets_included,
             p.id as plan_id,
             p.code as plan_code,
             p.name as plan_name,
             p.description as plan_description,
             p.price_cents as plan_price_cents,
             p.currency as plan_currency,
             p.billing_period as plan_billing_period,
             p.included_chats as plan_included_chats,
             p.included_videos as plan_included_videos,
             p.pets_included_default as plan_pets_included_default,
             p.tax_rate as plan_tax_rate,
             p.is_active as plan_is_active
           from user_subscriptions s
           join subscription_plans p on p.id = s.plan_id
          where s.user_id = auth.uid()
          order by s.current_period_end desc nulls last`
        );
        return rows.map((r) => ({
          id: r.sub_id,
          status: r.status,
          current_period_start: r.current_period_start,
          current_period_end: r.current_period_end,
          cancel_at_period_end: r.cancel_at_period_end,
          pets_included: r.pets_included,
          plan: {
            id: r.plan_id,
            code: r.plan_code,
            name: r.plan_name,
            description: r.plan_description,
            price_cents: r.plan_price_cents,
            currency: r.plan_currency,
            billing_period: r.plan_billing_period,
            included_chats: r.plan_included_chats,
            included_videos: r.plan_included_videos,
            pets_included_default: r.plan_pets_included_default,
            tax_rate: r.plan_tax_rate,
            is_active: r.plan_is_active,
          },
        }));
      });
      return { data: rows };
    } catch (e: any) {
      throw new HttpException(e?.message || 'subscriptions_list_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get('recommendation')
  async recommendation(@Query('horses') horsesRaw?: string) {
    try {
      if (this.db.isStub) {
        return { ok: true, recommendedCode: null, strategy: 'stub' } as any;
      }

      const horsesTargetParsed = Number.parseInt((horsesRaw || '').trim(), 10);
      const horsesTarget = Number.isFinite(horsesTargetParsed) && horsesTargetParsed > 0
        ? horsesTargetParsed
        : null;

      const result = await this.db.runInTx(async (q) => {
        const plansRes = await q<any>(
          `select code, pets_included_default, coalesce(price_monthly_cents, price_cents) as monthly_price
             from subscription_plans
            where is_active = true
            order by pets_included_default asc nulls last, coalesce(price_monthly_cents, price_cents) asc nulls last`
        );
        const plans = plansRes.rows || [];
        if (!plans.length) {
          return { ok: false, reason: 'no_active_plans' } as any;
        }

        const userRes = await q<any>(
          `select customer_type
             from users
            where id = auth.uid()
            limit 1`
        );
        const customerType = ((userRes.rows[0]?.customer_type || '') as string).trim().toLowerCase() || null;

        let picked = null as any;
        let strategy = 'fallback_first_active_plan';

        if (horsesTarget !== null) {
          picked = plans.find((p: any) => {
            const coverage = Number(p?.pets_included_default || 0);
            return Number.isFinite(coverage) && coverage >= horsesTarget;
          }) || null;

          if (!picked) {
            picked = plans[plans.length - 1] || null;
          }
          strategy = 'horses_target';
        }

        if (!picked && customerType) {
          const suggestedCode = {
            owner: 'starter',
            caballerango: 'plus',
            veterinarian: 'cuadra',
            trainer: 'pro-entrenador',
            ranch_responsible: 'rancho-trabajo',
          }[customerType] || 'starter';

          picked = plans.find((p: any) => (p?.code || '').toLowerCase() === suggestedCode) || null;
          if (picked) {
            strategy = 'customer_type';
          }
        }

        if (!picked) {
          picked = plans[0] || null;
        }

        return {
          ok: true,
          recommendedCode: picked?.code ? String(picked.code).toLowerCase() : null,
          strategy,
          horsesTarget,
          customerType,
        };
      });

      return result;
    } catch (e: any) {
      throw new HttpException(e?.message || 'subscription_recommendation_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get('usage/current')
  async getCurrentUsage() {
    try {
      if (this.db.isStub) {
        return { ok: true, usage: { included_chats: 0, consumed_chats: 0, included_videos: 0, consumed_videos: 0, period_start: new Date().toISOString(), period_end: new Date().toISOString() }, msg: 'stub' } as any;
      }
      const usage = await this.db.runInTx(async (q) => {
        // Use underlying table to include scheduled-cancel subs until period end
        const { rows: subs } = await q<{ id: string }>(
          `select id
             from user_subscriptions
            where user_id = auth.uid()
              and status = 'active'
              and coalesce(current_period_end, now()) > now()
            order by current_period_end desc nulls last
            limit 1`
        );
        if (!subs[0]) return null;
        const subId = subs[0].id;
        const { rows } = await q<any>(`select * from fn_current_usage(trim($1)::uuid)`, [subId]);
        const u = rows[0] || null;
        return u ? {
          included_chats: u.included_chats,
          consumed_chats: u.consumed_chats,
          included_videos: u.included_videos,
          consumed_videos: u.consumed_videos,
          period_start: u.period_start,
          period_end: u.period_end,
        } : null;
      });
      if (!usage) {
        return { ok: false, reason: 'no_active_subscription', message: 'No active subscription. Acquire a plan to access usage.', usage: null } as any;
      }
      return { ok: true, usage } as any;
    } catch (e: any) {
      throw new HttpException(e?.message || 'usage_current_failed', HttpStatus.BAD_REQUEST);
    }
  }

  // Dev-only: introspect auth.uid() and subscription visibility
  // Note: debug endpoint removed (dev-only)
}