import { Body, Controller, Get, HttpException, HttpStatus, Post, UseGuards, Req } from '@nestjs/common';
import { PriceService } from './price.service';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';

@Controller('subscriptions')
@UseGuards(AuthGuard)
export class SubscriptionsController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext, private readonly prices: PriceService) {}

  // ---- Lifecycle stubs (checkout/portal/cancel/resume/change-plan) ----
  // These are intentionally not implemented yet. Return NOT_IMPLEMENTED (501) with structured payload
  // so the Observability UI can distinguish between "missing route" (404) and "planned but deferred".

  @Post('checkout')
  async checkout(@Body() body: { plan_code?: string; seats?: number }) {
    try {
      if (this.db.isStub) return { ok: true, stub: true, reason: 'db_unavailable' } as any;
      const planCode = (body?.plan_code || '').trim();
      if (!planCode) return { ok: false, reason: 'validation_error', details: 'plan_code required' };
      const dbgClaims = this.rc.claims || null;
      const row = await this.db.runInTx(async (q) => {
        // Ensure auth.uid() is available; if not, attempt to derive from request context claims
        const uidRow = await q(`select auth.uid()::text as uid`);
        const uid = uidRow.rows[0]?.uid;
        if (!uid) {
          return { noAuthUid: true, dbgClaims } as any;
        }
        // Ensure no active subscription
        const active = await q(`select id from v_active_user_subscriptions where user_id = auth.uid() limit 1`);
        if (active.rows[0]) return { alreadyActive: true } as any;
        const plan = await q(
          `select id, code, name, description, price_cents, currency, billing_period, included_chats, included_videos, pets_included_default, tax_rate
             from subscription_plans
            where is_active = true and lower(code) = lower($1)
            limit 1`,
          [planCode]
        );
        if (!plan.rows[0]) return { planNotFound: true } as any;
        const billingPeriod = plan.rows[0].billing_period || 'month';
        const seats = body?.seats && body.seats > 0 ? body.seats : plan.rows[0].pets_included_default || 1;
        // Period end calculation
        const sub = await q(
          `insert into user_subscriptions(
             id, user_id, plan_id, status, current_period_start, current_period_end, cancel_at_period_end, pets_included
           ) values (
             gen_random_uuid(), auth.uid(), $1::uuid, 'active', now(),
             (now() + case when $2 = 'month' then interval '1 month' when $2 = 'year' then interval '1 year' else interval '1 month' end),
             false, $3
           ) returning id, plan_id, status, current_period_start, current_period_end, cancel_at_period_end, pets_included`,
          [plan.rows[0].id, billingPeriod, seats]
        );
        const usage = await q(
          `insert into subscription_usage(
             id, subscription_id, period_start, period_end, included_chats, included_videos, consumed_chats, consumed_videos
           ) values (
             gen_random_uuid(), $1::uuid, $2, $3, $4, $5, 0, 0
           ) returning id`,
          [sub.rows[0].id, sub.rows[0].current_period_start, sub.rows[0].current_period_end, plan.rows[0].included_chats, plan.rows[0].included_videos]
        );
        return { plan: plan.rows[0], sub: sub.rows[0], usageId: usage.rows[0].id };
      });
      if ((row as any).alreadyActive) return { ok: false, reason: 'already_has_active_subscription' };
      if ((row as any).planNotFound) return { ok: false, reason: 'plan_not_found' };
      if ((row as any).noAuthUid) return { ok: false, reason: 'unauthenticated', details: 'JWT missing or invalid', dbgClaims: (row as any).dbgClaims };
      const plan = (row as any).plan;
      const sub = (row as any).sub;
      return {
        ok: true,
        action: 'checkout',
        subscription: {
          id: sub.id,
          status: sub.status,
          current_period_start: sub.current_period_start,
          current_period_end: sub.current_period_end,
          cancel_at_period_end: sub.cancel_at_period_end,
          pets_included: sub.pets_included,
          plan: {
            id: plan.id,
            code: plan.code,
            name: plan.name,
            description: plan.description,
            price_cents: plan.price_cents,
            currency: plan.currency,
            billing_period: plan.billing_period,
            included_chats: plan.included_chats,
            included_videos: plan.included_videos,
            pets_included_default: plan.pets_included_default,
            tax_rate: plan.tax_rate,
          },
        },
      };
    } catch (e: any) {
      throw new (require('@nestjs/common').HttpException)({ ok: false, reason: 'checkout_failed', error: e?.message }, 400);
    }
  }

  // New Stripe Checkout Session endpoint enforcing metadata.user_id
  @Post('stripe/checkout')
  async stripeCheckout(@Body() body: { plan_code?: string; success_url?: string; cancel_url?: string }, @Req() req: any) {
    const planCode = (body?.plan_code || '').trim();
    if (!planCode) throw new HttpException({ ok: false, reason: 'plan_code_required' }, HttpStatus.BAD_REQUEST);
    const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    // Primary: ALS request context
    let claimsSub: string | null = (this.rc.claims && (this.rc.claims as any).sub) || null;
    // Fallback: guard-attached authClaims
    if (!claimsSub && req?.authClaims?.sub) claimsSub = req.authClaims.sub;
    // Fallback: header x-user-id (dev only)
    if (!claimsSub && req?.headers?.['x-user-id']) {
      const raw = Array.isArray(req.headers['x-user-id']) ? req.headers['x-user-id'][0] : req.headers['x-user-id'];
      const val = (raw || '').toString().trim();
      if (uuidRegex.test(val)) claimsSub = val;
    }
    // Optional env override for local smoke
    if (!claimsSub && process.env.DEV_TEST_USER_ID && uuidRegex.test(process.env.DEV_TEST_USER_ID)) {
      claimsSub = process.env.DEV_TEST_USER_ID;
    }
    const userId = claimsSub && uuidRegex.test(claimsSub) ? claimsSub : null;
    if (!userId) throw new HttpException({ ok: false, reason: 'unauthenticated', detail: 'claims.sub missing or invalid UUID', dbg: { rcClaims: this.rc.claims || null, authClaims: req?.authClaims || null } }, HttpStatus.UNAUTHORIZED);
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
    // Placeholder: backend returns a pending_frontend status so UI can build Stripe portal link.
    // If STRIPE_PORTAL_BASE_URL env is set, include it; otherwise null.
    const base = process.env.STRIPE_PORTAL_BASE_URL || null;
    return {
      ok: true,
      action: 'portal',
      status: 'pending_frontend',
      stripePortalUrl: base ? `${base}?session=create` : null,
      reason: 'frontend_todo',
      message: 'Portal integration to be finished in frontend.'
    };
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
        const { rows: subs } = await q<{ id: string }>(
          `select id from v_active_user_subscriptions where user_id = auth.uid() order by current_period_end desc limit 1`
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

  @Get('usage/current')
  async getCurrentUsage() {
    try {
      if (this.db.isStub) {
        return { ok: true, usage: { included_chats: 0, consumed_chats: 0, included_videos: 0, consumed_videos: 0, period_start: new Date().toISOString(), period_end: new Date().toISOString() }, msg: 'stub' } as any;
      }
      const usage = await this.db.runInTx(async (q) => {
        const { rows: subs } = await q<{ id: string }>(
          `select id from v_active_user_subscriptions where user_id = auth.uid() order by current_period_end desc limit 1`
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
