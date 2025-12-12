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
    const sql = `select id, email, full_name, role, is_verified, created_at
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
      `select id, email, full_name, role, is_verified, created_at, updated_at from users where id = $1`,
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
    @Body() body: { userId: string; code: string; delta: number }
  ) {
    assertAdmin(secret);
    if (!body?.userId || !body?.code || typeof body?.delta !== 'number') {
      throw new BadRequestException('userId, code, delta required');
    }
    // TODO: implement real credits ledger update
    return { ok: true, code: body.code, delta: body.delta, remaining: null, stub: true };
  }

  @Post('refunds')
  async refunds(
    @Headers('x-admin-secret') secret: string,
    @Body() body: { paymentId: string; amount?: number; reason?: string }
  ) {
    assertAdmin(secret);
    if (!body?.paymentId) throw new BadRequestException('paymentId required');
    // TODO: call Stripe refunds API and update DB
    return { ok: true, paymentId: body.paymentId, amount: body.amount ?? null, reason: body.reason ?? null, stub: true };
  }

  @Post('vets/:vetId/approve')
  async approveVet(
    @Headers('x-admin-secret') secret: string,
    @Param('vetId') vetId: string
  ) {
    assertAdmin(secret);
    if (!vetId) throw new BadRequestException('vetId required');
    // TODO: update vets table set approved=true where id=vetId
    return { ok: true, vetId, approved: true, stub: true };
  }

  @Post('plans')
  async upsertPlan(
    @Headers('x-admin-secret') secret: string,
    @Body() body: { code: string; name: string; price_cents?: number; currency?: string }
  ) {
    assertAdmin(secret);
    if (!body?.code || !body?.name) throw new BadRequestException('code, name required');
    // TODO: insert/update subscription_plans
    return { ok: true, plan: { code: body.code, name: body.name, price_cents: body.price_cents ?? null, currency: body.currency ?? 'usd' }, stub: true };
  }

  @Post('coupons')
  async createCoupon(
    @Headers('x-admin-secret') secret: string,
    @Body() body: { code: string; percent_off?: number; amount_off_cents?: number }
  ) {
    assertAdmin(secret);
    if (!body?.code) throw new BadRequestException('code required');
    // TODO: insert coupon row and optionally sync to Stripe
    return { ok: true, coupon: { code: body.code, percent_off: body.percent_off ?? null, amount_off_cents: body.amount_off_cents ?? null }, stub: true };
  }

  @Get('analytics/usage')
  async analyticsUsage(@Headers('x-admin-secret') secret: string) {
    assertAdmin(secret);
    // TODO: aggregate queries for usage KPIs
    return { ok: true, metrics: { users: null, activeSubscriptions: null, sessionsThisMonth: null }, stub: true };
  }
}
