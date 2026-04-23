import { BadRequestException, Body, Controller, ForbiddenException, Get, Headers, Param, Post, Query } from '@nestjs/common';
import { DbService } from '../db/db.service';

function assertAdmin(secretHeader?: string) {
  const expected = process.env.ADMIN_PRICING_SYNC_SECRET || process.env.ADMIN_SECRET || '';
  if (!expected || secretHeader !== expected) {
    throw new ForbiddenException('invalid admin secret');
  }
}

@Controller('admin')
export class AdminController {
  constructor(private readonly db: DbService) {}

  @Get('users')
  async listUsers(
    @Headers('x-admin-secret') secret: string,
    @Query('q') q?: string,
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string
  ) {
    assertAdmin(secret);
    const limit = Math.min(Math.max(parseInt(limitStr || '50', 10) || 50, 1), 200);
    const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
    const params: any[] = [];
    let where = '';
    if (q && q.trim()) {
      params.push(`%${q.trim().toLowerCase()}%`);
      where = 'where lower(email) like $1 or lower(coalesce(full_name,\'\')) like $1';
    }
    const sql = `select id, email, full_name, customer_type, role, is_verified, created_at
                   from users ${where}
                  order by created_at desc
                  limit ${limit} offset ${offset}`;
    const { rows } = await (this.db as any).query(sql, params);
    return { data: rows };
  }

  @Get('users/:userId')
  async userDetail(@Headers('x-admin-secret') secret: string, @Param('userId') userId: string) {
    assertAdmin(secret);
    if (!userId) throw new BadRequestException('userId required');
    const { rows } = await (this.db as any).query(
      `select id, email, full_name, customer_type, role, is_verified, created_at, updated_at from users where id = $1`,
      [userId]
    );
    if (!rows.length) throw new BadRequestException('not_found');
    return rows[0];
  }

  @Get('subscriptions')
  async listSubscriptions(
    @Headers('x-admin-secret') secret: string,
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string
  ) {
    assertAdmin(secret);
    const limit = Math.min(Math.max(parseInt(limitStr || '50', 10) || 50, 1), 200);
    const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
    const sql = `
      select s.id, s.user_id, s.status, s.current_period_start, s.current_period_end,
             p.id as plan_id, p.code as plan_code, p.name as plan_name
        from user_subscriptions s
        left join subscription_plans p on p.id = s.plan_id
       order by s.current_period_end desc nulls last, s.created_at desc
       limit ${limit} offset ${offset}`;
    const { rows } = await (this.db as any).query(sql);
    return { data: rows };
  }

  @Post('credits/grant')
  async grantCredits(
    @Headers('x-admin-secret') secret: string,
    @Body() body: { userId?: string; user_id?: string; code?: string; delta?: number; credits?: number; type?: 'chat'|'video'; expires_at?: string }
  ) {
    assertAdmin(secret);
    const userId = (body?.userId || body?.user_id || '').trim();
    const code = ((body?.code || '').trim() || (body?.type === 'video' ? 'video_unit' : body?.type === 'chat' ? 'chat_unit' : '')).trim();
    const delta = typeof body?.delta === 'number' ? Math.trunc(body.delta) : typeof body?.credits === 'number' ? Math.trunc(body.credits) : NaN;
    if (!userId || !code || !Number.isFinite(delta) || delta === 0) {
      throw new BadRequestException('userId/user_id, code or type, and non-zero delta/credits required');
    }

    const result = await this.db.runInTx(async (q) => {
      const { rows: itemRows } = await q<{ id: string }>(
        `select id from overage_items where lower(code)=lower($1) limit 1`,
        [code]
      );
      if (!itemRows[0]) return { itemNotFound: true } as any;
      const itemId = itemRows[0].id;

      const { rows: creditRows } = await q<{ id: string; remaining_units: number }>(
        `select id, remaining_units
           from overage_credits
          where user_id = $1::uuid
            and overage_item_id = $2::uuid
          limit 1
          for update`,
        [userId, itemId]
      );

      if (creditRows[0]) {
        const { rows: updated } = await q<{ remaining_units: number }>(
          `update overage_credits
              set remaining_units = greatest(remaining_units + $2, 0),
                  expires_at = coalesce($3::timestamptz, expires_at),
                  updated_at = now()
            where id = $1::uuid
            returning remaining_units`,
          [creditRows[0].id, delta, body?.expires_at || null]
        );
        return { remaining: updated[0]?.remaining_units ?? 0 };
      }

      if (delta < 0) {
        return { missingCreditRow: true } as any;
      }

      const { rows: inserted } = await q<{ remaining_units: number }>(
        `insert into overage_credits (id, user_id, overage_item_id, remaining_units, expires_at, created_at, updated_at)
         values (gen_random_uuid(), $1::uuid, $2::uuid, $3, $4::timestamptz, now(), now())
         returning remaining_units`,
        [userId, itemId, delta, body?.expires_at || null]
      );
      return { remaining: inserted[0]?.remaining_units ?? 0 };
    });

    if ((result as any).itemNotFound) throw new BadRequestException('item_not_found');
    if ((result as any).missingCreditRow) throw new BadRequestException('no_existing_credit_row');

    return { ok: true, userId, code, delta, remaining: (result as any).remaining };
  }

  @Post('refunds')
  async refunds(
    @Headers('x-admin-secret') secret: string,
    @Body() body: { paymentId: string; amount?: number; reason?: string; requestId?: string }
  ) {
    assertAdmin(secret);
    if (!body?.paymentId) throw new BadRequestException('paymentId required');
    const sk = process.env.STRIPE_SECRET_KEY || '';
    const pid = (body.paymentId || '').trim();
    const amt = typeof body.amount === 'number' ? Math.trunc(body.amount) : undefined;
    const reason = (body.reason || '').trim();
    // Dev fallback: allow stubbed response if no Stripe key or obvious test id
    if (!sk || pid.startsWith('test_') || pid === 'test_payment_id') {
      return { ok: true, mode: 'dev_fallback', paymentId: pid, amount: amt ?? null, reason: reason || null };
    }
    try {
      // Lazy require to avoid import at module load
      // eslint-disable-next-line @typescript-eslint/no-var-requires
      const Stripe = require('stripe');
      const stripe = new Stripe(sk, { apiVersion: '2024-06-20' });
      const params: any = { payment_intent: pid };
      if (typeof amt === 'number' && Number.isFinite(amt) && amt > 0) params.amount = amt;
      // Map human reason to Stripe enum if provided
      if (reason) {
        const map: Record<string, string> = {
          'requested_by_customer': 'requested_by_customer',
          'duplicate': 'duplicate',
          'fraudulent': 'fraudulent'
        };
        const r = map[reason] || undefined;
        if (r) params.reason = r;
      }
      const headers: any = {};
      if (body.requestId) headers['Idempotency-Key'] = `admin-refund:${body.requestId}`;
      const refund = await stripe.refunds.create(params, { idempotencyKey: headers['Idempotency-Key'] });
      return {
        ok: true,
        refund_id: refund.id,
        status: refund.status,
        amount: refund.amount,
        currency: refund.currency,
        payment_intent: refund.payment_intent,
      };
    } catch (e: any) {
      throw new BadRequestException(e?.message || 'stripe_refund_failed');
    }
  }

  @Post('vets/:vetId/approve')
  async approveVet(
    @Headers('x-admin-secret') secret: string,
    @Param('vetId') vetId: string
  ) {
    assertAdmin(secret);
    if (!vetId) throw new BadRequestException('vetId required');
    const { rows } = await (this.db as any).query(
      `update vets
          set is_approved = true,
              updated_at = now()
        where id = $1::uuid
        returning id, license_number, country, bio, years_experience, is_approved, specialties, languages`,
      [vetId]
    );
    if (!rows.length) throw new BadRequestException('not_found');
    return rows[0];
  }

  @Post('plans')
  async upsertPlan(
    @Headers('x-admin-secret') secret: string,
    @Body() body: {
      code: string;
      name: string;
      description?: string;
      price_cents?: number;
      currency?: string;
      billing_period?: 'month'|'year';
      included_chats?: number;
      included_videos?: number;
      pets_included_default?: number;
      tax_rate?: number;
      is_active?: boolean;
    }
  ) {
    assertAdmin(secret);
    if (!body?.code || !body?.name) throw new BadRequestException('code, name required');

    const result = await this.db.runInTx(async (q) => {
      const { rows: existing } = await q<any>(
        `select id
           from subscription_plans
          where lower(code) = lower($1)
          limit 1
          for update`,
        [body.code]
      );

      if (existing[0]) {
        const { rows } = await q<any>(
          `update subscription_plans
              set name = $2,
                  description = coalesce($3, description),
                  price_cents = coalesce($4, price_cents),
                  currency = coalesce($5, currency),
                  billing_period = coalesce($6, billing_period),
                  included_chats = coalesce($7, included_chats),
                  included_videos = coalesce($8, included_videos),
                  pets_included_default = coalesce($9, pets_included_default),
                  tax_rate = coalesce($10, tax_rate),
                  is_active = coalesce($11, is_active),
                  updated_at = now()
            where id = $1::uuid
            returning *`,
          [
            existing[0].id,
            body.name,
            body.description ?? null,
            body.price_cents ?? null,
            body.currency ?? null,
            body.billing_period ?? null,
            body.included_chats ?? null,
            body.included_videos ?? null,
            body.pets_included_default ?? null,
            body.tax_rate ?? null,
            body.is_active ?? null,
          ]
        );
        return rows[0];
      }

      if (typeof body.price_cents !== 'number') {
        throw new BadRequestException('price_cents required when creating a new plan');
      }

      const { rows } = await q<any>(
        `insert into subscription_plans (
           id, code, name, description, price_cents, currency, billing_period,
           included_chats, included_videos, pets_included_default, tax_rate, is_active,
           created_at, updated_at
         ) values (
           gen_random_uuid(), $1, $2, $3, $4, $5, $6,
           $7, $8, $9, $10, $11,
           now(), now()
         )
         returning *`,
        [
          body.code,
          body.name,
          body.description ?? null,
          body.price_cents,
          body.currency ?? 'MXN',
          body.billing_period ?? 'month',
          body.included_chats ?? 0,
          body.included_videos ?? 0,
          body.pets_included_default ?? 1,
          body.tax_rate ?? 0.16,
          body.is_active ?? true,
        ]
      );
      return rows[0];
    });

    return result;
  }

  @Get('analytics/usage')
  async analyticsUsage(@Headers('x-admin-secret') secret: string) {
    assertAdmin(secret);
    const [users, activeSubscriptions, sessionsThisMonth] = await Promise.all([
      (this.db as any).query(`select count(*)::int as count from users where deleted_at is null`),
      (this.db as any).query(
        `select count(*)::int as count
           from user_subscriptions
          where status in ('trialing','active')
            and coalesce(current_period_end, now()) > now()`
      ),
      (this.db as any).query(
        `select count(*)::int as count
           from chat_sessions
          where created_at >= date_trunc('month', now())`
      ),
    ]);

    return {
      ok: true,
      metrics: {
        users: users.rows[0]?.count ?? 0,
        activeSubscriptions: activeSubscriptions.rows[0]?.count ?? 0,
        sessionsThisMonth: sessionsThisMonth.rows[0]?.count ?? 0,
      },
      generatedAt: new Date().toISOString(),
    };
  }
}
