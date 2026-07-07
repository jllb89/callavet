import { BadRequestException, Body, Controller, ForbiddenException, Get, Headers, Param, Post, Query } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';

function assertAdmin(secretHeader?: string) {
  const expected = process.env.ADMIN_PRICING_SYNC_SECRET || process.env.ADMIN_SECRET || '';
  if (!expected || secretHeader !== expected) {
    throw new ForbiddenException('invalid admin secret');
  }
}

@Controller('admin')
export class AdminController {
  constructor(
    private readonly db: DbService,
    private readonly rc: RequestContext,
  ) {}

  private async logAdminAction(action: string, targetType?: string | null, targetId?: string | null, metadata?: Record<string, any>) {
    try {
      await this.db.query(
        `insert into admin_audit_logs (
           id,
           actor_user_id,
           action,
           target_type,
           target_id,
           metadata,
           created_at
         ) values (
           gen_random_uuid(),
           $1::uuid,
           $2,
           $3,
           $4,
           coalesce($5::jsonb, '{}'::jsonb),
           now()
         )`,
        [this.rc.userId || null, action, targetType || null, targetId || null, JSON.stringify(metadata || {})]
      );
    } catch {
      // Audit logging must never break admin operations.
    }
  }

  private async tableExists(tableName: string) {
    const { rows } = await this.db.query<{ exists: boolean }>(
      `select to_regclass($1) is not null as exists`,
      [tableName]
    );
    return rows[0]?.exists === true;
  }

  private async safeCount(sql: string, params: any[] = []) {
    try {
      const { rows } = await this.db.query<{ count: number }>(sql, params);
      return rows[0]?.count ?? 0;
    } catch {
      return 0;
    }
  }

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
    await this.logAdminAction('admin.users.list', 'users', null, { q: q || null, limit, offset, count: rows.length });
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
    await this.logAdminAction('admin.users.detail', 'users', userId);
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
    await this.logAdminAction('admin.subscriptions.list', 'subscriptions', null, { limit, offset, count: rows.length });
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

    await this.logAdminAction('admin.credits.grant', 'overage_credits', userId, {
      code,
      delta,
      remaining: (result as any).remaining,
    });

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
      await this.logAdminAction('admin.refunds.create', 'payments', pid, {
        mode: 'dev_fallback',
        amount: amt ?? null,
        reason: reason || null,
      });
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
      await this.logAdminAction('admin.refunds.create', 'payments', pid, {
        mode: 'stripe',
        refund_id: refund.id,
        amount: refund.amount,
        currency: refund.currency,
      });
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
    await this.logAdminAction('admin.vets.approve', 'vets', vetId);
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

    await this.logAdminAction('admin.plans.upsert', 'subscription_plans', (result as any)?.id || null, {
      code: body.code,
      name: body.name,
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

  @Get('notifications/events')
  async listNotificationEvents(
    @Headers('x-admin-secret') secret: string,
    @Query('status') status?: string,
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string,
  ) {
    assertAdmin(secret);
    const limit = Math.min(Math.max(parseInt(limitStr || '50', 10) || 50, 1), 200);
    const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
    const where = status ? 'where status = $1' : '';
    const args = status ? [status] : [];
    const { rows } = await this.db.query(
      `select id, user_id, event_type, channel, destination, status, provider, provider_message_id, error_text, created_at, sent_at
         from notification_events
         ${where}
        order by created_at desc
        limit ${limit} offset ${offset}`,
      args,
    );
    await this.logAdminAction('admin.notifications.events.list', 'notification_events', null, {
      status: status || null,
      limit,
      offset,
      count: rows.length,
    });
    return { data: rows };
  }

  @Get('audit/logs')
  async listAuditLogs(
    @Headers('x-admin-secret') secret: string,
    @Query('action') action?: string,
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string,
  ) {
    assertAdmin(secret);
    const limit = Math.min(Math.max(parseInt(limitStr || '100', 10) || 100, 1), 500);
    const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
    const where = action ? 'where action = $1' : '';
    const args = action ? [action] : [];
    const { rows } = await this.db.query(
      `select id, actor_user_id, action, target_type, target_id, metadata, created_at
         from admin_audit_logs
         ${where}
        order by created_at desc
        limit ${limit} offset ${offset}`,
      args,
    );
    return { data: rows };
  }

  @Get('export/sessions')
  async exportSessions(
    @Headers('x-admin-secret') secret: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('limit') limitStr?: string,
  ) {
    assertAdmin(secret);
    const limit = Math.min(Math.max(parseInt(limitStr || '1000', 10) || 1000, 1), 5000);
    const { rows } = await this.db.query(
      `select s.id,
              s.user_id,
              s.vet_id,
              s.status,
              s.mode,
              s.started_at,
              s.ended_at,
              s.created_at,
              (select count(*)::int from messages m where m.session_id = s.id) as messages_count,
              (select count(*)::int from consultation_notes n where n.session_id = s.id) as notes_count,
              (
                select count(*)::int
                  from care_plans cp
                  join clinical_encounters ce on ce.id = cp.encounter_id
                 where ce.session_id = s.id
              ) as care_plans_count
         from chat_sessions s
        where ($1::timestamptz is null or s.created_at >= $1::timestamptz)
          and ($2::timestamptz is null or s.created_at <= $2::timestamptz)
        order by s.created_at desc
        limit ${limit}`,
      [from || null, to || null],
    );
    await this.logAdminAction('admin.export.sessions', 'chat_sessions', null, {
      from: from || null,
      to: to || null,
      count: rows.length,
      limit,
    });
    return { ok: true, exportedAt: new Date().toISOString(), data: rows };
  }

  @Get('export/notes')
  async exportNotes(
    @Headers('x-admin-secret') secret: string,
    @Query('from') from?: string,
    @Query('to') to?: string,
    @Query('limit') limitStr?: string,
  ) {
    assertAdmin(secret);
    const limit = Math.min(Math.max(parseInt(limitStr || '1000', 10) || 1000, 1), 5000);
    const { rows } = await this.db.query(
      `select n.id,
              n.session_id,
              n.vet_id,
              n.pet_id,
              n.severity,
              n.summary_text,
              n.assessment_text,
              n.diagnosis_text,
              n.plan_summary,
              n.next_follow_up_at,
              n.created_at
         from consultation_notes n
        where ($1::timestamptz is null or n.created_at >= $1::timestamptz)
          and ($2::timestamptz is null or n.created_at <= $2::timestamptz)
        order by n.created_at desc
        limit ${limit}`,
      [from || null, to || null],
    );
    await this.logAdminAction('admin.export.notes', 'consultation_notes', null, {
      from: from || null,
      to: to || null,
      count: rows.length,
      limit,
    });
    return { ok: true, exportedAt: new Date().toISOString(), data: rows };
  }

  @Get('video/sessions')
  async adminVideoSessions(
    @Headers('x-admin-secret') secret: string,
    @Query('limit') limitQ?: string,
    @Query('offset') offsetQ?: string,
    @Query('status') statusQ?: string,
  ) {
    assertAdmin(secret);
    const limit = Math.min(Math.max(Number(limitQ) || 50, 1), 200);
    const offset = Math.max(Number(offsetQ) || 0, 0);
    const allowedStatuses = ['pending', 'waiting', 'live', 'ended', 'released', 'timed_out', 'host_absent', 'forced_ended'];
    const statusFilter = statusQ && allowedStatuses.includes(statusQ) ? statusQ : null;

    const { rows } = await this.db.query<{
      session_id: string;
      room_name: string | null;
      room_sid: string | null;
      status: string;
      first_room_started_at: string | null;
      first_both_joined_at: string | null;
      room_finished_at: string | null;
      entitlement_finalized_at: string | null;
      entitlement_released_at: string | null;
      safety_reason: string | null;
      egress_id: string | null;
      egress_started_at: string | null;
      egress_ended_at: string | null;
      recording_url: string | null;
      created_at: string;
      updated_at: string;
    }>(
      `select v.session_id,
              v.room_name,
              v.room_sid,
              v.status,
              v.first_room_started_at,
              v.first_both_joined_at,
              v.room_finished_at,
              v.entitlement_finalized_at,
              v.entitlement_released_at,
              v.safety_reason,
              v.egress_id,
              v.egress_started_at,
              v.egress_ended_at,
              v.recording_url,
              v.created_at,
              v.updated_at
         from video_session_lifecycle v
        where ($1::text is null or v.status = $1)
        order by v.updated_at desc
        limit $2 offset $3`,
      [statusFilter, limit, offset]
    );

    await this.logAdminAction('admin.video.sessions.list', 'video_session_lifecycle', null, { limit, offset, statusFilter, count: rows.length });
    return { ok: true, count: rows.length, limit, offset, data: rows };
  }

  @Get('ops/dashboard')
  async opsDashboard(@Headers('x-admin-secret') secret: string) {
    assertAdmin(secret);
    const [hasVideoLifecycle, hasAiJobRuns, hasWsAuthFailures] = await Promise.all([
      this.tableExists('public.video_session_lifecycle'),
      this.tableExists('public.ai_job_runs'),
      this.tableExists('public.ws_auth_failures'),
    ]);

    const [
      sessions24h,
      messages24h,
      notifications24h,
      failedNotifications24h,
      pendingNotifications,
      refunds24h,
      videoFailureModes24h,
      roomIssuanceFailures24h,
      wsAuthFailures24h,
      aiJobErrors24h,
    ] = await Promise.all([
      this.safeCount(`select count(*)::int as count from chat_sessions where created_at >= now() - interval '24 hours'`),
      this.safeCount(`select count(*)::int as count from messages where created_at >= now() - interval '24 hours'`),
      this.safeCount(`select count(*)::int as count from notification_events where created_at >= now() - interval '24 hours'`),
      this.safeCount(`select count(*)::int as count from notification_events where status = 'failed' and created_at >= now() - interval '24 hours'`),
      this.safeCount(`select count(*)::int as count from notification_events where status = 'queued'`),
      this.safeCount(`select count(*)::int as count from admin_audit_logs where action = 'admin.refunds.create' and created_at >= now() - interval '24 hours'`),
      hasVideoLifecycle
        ? this.safeCount(
            `select count(*)::int as count
               from video_session_lifecycle
              where updated_at >= now() - interval '24 hours'
                and status in ('timed_out', 'host_absent', 'forced_ended')`
          )
        : Promise.resolve(0),
      hasVideoLifecycle
        ? this.safeCount(
            `select count(*)::int as count
               from video_session_lifecycle
              where updated_at >= now() - interval '24 hours'
                and (
                  safety_reason in ('provider_create_failed', 'token_issue_failed', 'livekit_not_configured')
                  or (status = 'forced_ended' and safety_reason = 'forced_end')
                )`
          )
        : Promise.resolve(0),
      hasWsAuthFailures
        ? this.safeCount(`select count(*)::int as count from ws_auth_failures where created_at >= now() - interval '24 hours'`)
        : this.safeCount(
            `select count(*)::int as count
               from admin_audit_logs
              where created_at >= now() - interval '24 hours'
                and (
                  action ilike 'ws.%auth%fail%'
                  or action ilike 'chat.%auth%fail%'
                  or action ilike 'realtime.%auth%fail%'
                )`
          ),
      hasAiJobRuns
        ? this.safeCount(
            `select count(*)::int as count
               from ai_job_runs
              where created_at >= now() - interval '24 hours'
                and status in ('failed', 'error')`
          )
        : this.safeCount(
            `select count(*)::int as count
               from admin_audit_logs
              where created_at >= now() - interval '24 hours'
                and (
                  action ilike 'ai.%error%'
                  or action ilike 'ai.%fail%'
                  or (
                    action ilike 'ai.%'
                    and (
                      metadata ? 'error'
                      or metadata ? 'exception'
                    )
                  )
                )`
          ),
    ]);

    const metrics = {
      sessions24h,
      messages24h,
      notifications24h,
      failedNotifications24h,
      pendingNotifications,
      refunds24h,
      videoFailureModes24h,
      roomIssuanceFailures24h,
      wsAuthFailures24h,
      aiJobErrors24h,
      telemetry: {
        videoLifecycle: hasVideoLifecycle,
        wsAuthFailuresTable: hasWsAuthFailures,
        aiJobRunsTable: hasAiJobRuns,
      },
    };

    const alerts = [
      {
        key: 'notifications.failed.rate',
        severity: metrics.failedNotifications24h > 25 ? 'critical' : metrics.failedNotifications24h > 5 ? 'warning' : 'ok',
        value: metrics.failedNotifications24h,
        threshold: 5,
      },
      {
        key: 'notifications.queue.depth',
        severity: metrics.pendingNotifications > 100 ? 'warning' : 'ok',
        value: metrics.pendingNotifications,
        threshold: 100,
      },
      {
        key: 'video.failure.modes',
        severity: metrics.videoFailureModes24h > 15 ? 'critical' : metrics.videoFailureModes24h > 3 ? 'warning' : 'ok',
        value: metrics.videoFailureModes24h,
        threshold: 3,
      },
      {
        key: 'video.room_issuance.failures',
        severity: metrics.roomIssuanceFailures24h > 8 ? 'critical' : metrics.roomIssuanceFailures24h > 1 ? 'warning' : 'ok',
        value: metrics.roomIssuanceFailures24h,
        threshold: 1,
      },
      {
        key: 'realtime.ws_auth.failures',
        severity: metrics.wsAuthFailures24h > 20 ? 'critical' : metrics.wsAuthFailures24h > 5 ? 'warning' : 'ok',
        value: metrics.wsAuthFailures24h,
        threshold: 5,
      },
      {
        key: 'ai.job.errors',
        severity: metrics.aiJobErrors24h > 10 ? 'critical' : metrics.aiJobErrors24h > 2 ? 'warning' : 'ok',
        value: metrics.aiJobErrors24h,
        threshold: 2,
      },
    ];

    await this.logAdminAction('admin.ops.dashboard.read', 'ops', null, { metrics, alerts });
    return { ok: true, generatedAt: new Date().toISOString(), metrics, alerts };
  }

  @Get('ops/chat-consultations')
  async chatConsultationOps(@Headers('x-admin-secret') secret: string) {
    assertAdmin(secret);
    const hasReceipts = await this.tableExists('public.message_receipts');
    const hasSurveys = await this.tableExists('public.consult_surveys');
    const hasEntitlements = await this.tableExists('public.entitlement_consumptions');

    const { rows } = await this.db.query<any>(
      `with recent_sessions as (
         select s.id,
                s.status,
                s.created_at,
                s.ended_at,
                s.updated_at
           from chat_sessions s
          where coalesce(s.mode, 'chat') = 'chat'
            and s.created_at >= now() - interval '24 hours'
       ), first_owner_message as (
         select m.session_id, min(m.created_at) as first_owner_at
           from messages m
           join recent_sessions rs on rs.id = m.session_id
          where m.role = 'user'
          group by m.session_id
       ), first_vet_message as (
         select m.session_id, min(m.created_at) as first_vet_at
           from messages m
           join recent_sessions rs on rs.id = m.session_id
          where m.role = 'vet'
          group by m.session_id
       ), session_message_counts as (
         select m.session_id, count(*)::int as message_count
           from messages m
           join recent_sessions rs on rs.id = m.session_id
          where m.deleted_at is null
          group by m.session_id
       )
       select count(*)::int as sessions_created_24h,
              count(*) filter (where rs.status = 'active')::int as active_sessions_24h,
              count(*) filter (where rs.status = 'completed')::int as completed_sessions_24h,
              count(*) filter (where rs.status in ('canceled', 'no_show'))::int as not_completed_sessions_24h,
              count(*) filter (where fom.first_owner_at is not null)::int as sessions_with_owner_message_24h,
              count(*) filter (where fvm.first_vet_at is not null)::int as sessions_with_vet_response_24h,
              count(*) filter (where coalesce(smc.message_count, 0) = 0 and rs.status <> 'active')::int as abandoned_without_messages_24h,
              coalesce(sum(coalesce(smc.message_count, 0)), 0)::int as messages_in_recent_sessions_24h,
              round(avg(extract(epoch from (fvm.first_vet_at - fom.first_owner_at))) filter (where fom.first_owner_at is not null and fvm.first_vet_at is not null)::numeric, 2) as avg_first_vet_response_seconds_24h
         from recent_sessions rs
         left join first_owner_message fom on fom.session_id = rs.id
         left join first_vet_message fvm on fvm.session_id = rs.id
         left join session_message_counts smc on smc.session_id = rs.id`
    );
    const realtime = rows[0] || {};

    const [
      receipts24h,
      readReceipts24h,
      finalizedChatEntitlements24h,
      releasedChatEntitlements24h,
      surveysPrompted24h,
      surveysCompleted24h,
    ] = await Promise.all([
      hasReceipts
        ? this.safeCount(`select count(*)::int as count from message_receipts where delivered_at >= now() - interval '24 hours'`)
        : Promise.resolve(0),
      hasReceipts
        ? this.safeCount(`select count(*)::int as count from message_receipts where read_at >= now() - interval '24 hours'`)
        : Promise.resolve(0),
      hasEntitlements
        ? this.safeCount(
            `select count(*)::int as count
               from entitlement_consumptions
              where consumption_type = 'chat'
                and finalized = true
                and updated_at >= now() - interval '24 hours'`
          )
        : Promise.resolve(0),
      hasEntitlements
        ? this.safeCount(
            `select count(*)::int as count
               from entitlement_consumptions
              where consumption_type = 'chat'
                and canceled_at >= now() - interval '24 hours'`
          )
        : Promise.resolve(0),
      hasSurveys
        ? this.safeCount(`select count(*)::int as count from consult_surveys where prompted_at >= now() - interval '24 hours'`)
        : Promise.resolve(0),
      hasSurveys
        ? this.safeCount(`select count(*)::int as count from consult_surveys where completed_at >= now() - interval '24 hours'`)
        : Promise.resolve(0),
    ]);

    const metrics = {
      sessionsCreated24h: Number(realtime.sessions_created_24h || 0),
      activeSessions24h: Number(realtime.active_sessions_24h || 0),
      completedSessions24h: Number(realtime.completed_sessions_24h || 0),
      notCompletedSessions24h: Number(realtime.not_completed_sessions_24h || 0),
      sessionsWithOwnerMessage24h: Number(realtime.sessions_with_owner_message_24h || 0),
      sessionsWithVetResponse24h: Number(realtime.sessions_with_vet_response_24h || 0),
      abandonedWithoutMessages24h: Number(realtime.abandoned_without_messages_24h || 0),
      messagesInRecentSessions24h: Number(realtime.messages_in_recent_sessions_24h || 0),
      avgFirstVetResponseSeconds24h: realtime.avg_first_vet_response_seconds_24h == null ? null : Number(realtime.avg_first_vet_response_seconds_24h),
      receipts24h,
      readReceipts24h,
      finalizedChatEntitlements24h,
      releasedChatEntitlements24h,
      surveysPrompted24h,
      surveysCompleted24h,
      telemetry: {
        messageReceiptsTable: hasReceipts,
        consultSurveysTable: hasSurveys,
        entitlementConsumptionsTable: hasEntitlements,
      },
    };

    const alerts = [
      {
        key: 'chat_consultations.no_vet_response',
        severity: metrics.sessionsWithOwnerMessage24h > 0 && metrics.sessionsWithVetResponse24h === 0 ? 'warning' : 'ok',
        value: metrics.sessionsWithVetResponse24h,
        threshold: 1,
      },
      {
        key: 'chat_consultations.abandoned_without_messages',
        severity: metrics.abandonedWithoutMessages24h > 10 ? 'warning' : 'ok',
        value: metrics.abandonedWithoutMessages24h,
        threshold: 10,
      },
      {
        key: 'chat_consultations.receipts.missing',
        severity: !hasReceipts ? 'critical' : 'ok',
        value: hasReceipts ? 1 : 0,
        threshold: 1,
      },
      {
        key: 'chat_consultations.surveys.missing',
        severity: !hasSurveys ? 'critical' : 'ok',
        value: hasSurveys ? 1 : 0,
        threshold: 1,
      },
    ];

    await this.logAdminAction('admin.ops.chat_consultations.read', 'ops', null, { metrics, alerts });
    return { ok: true, generatedAt: new Date().toISOString(), metrics, alerts };
  }
}
