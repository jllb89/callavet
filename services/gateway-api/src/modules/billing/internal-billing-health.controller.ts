import { Controller, Get, Headers, ForbiddenException } from '@nestjs/common';
import { DbService } from '../db/db.service';

@Controller('internal/billing')
export class InternalBillingHealthController {
  constructor(private readonly db: DbService) {}

  @Get('health')
  async health(@Headers('x-internal-secret') secret: string) {
    if (!process.env.INTERNAL_STRIPE_EVENT_SECRET || secret !== process.env.INTERNAL_STRIPE_EVENT_SECRET) {
      throw new ForbiddenException('invalid secret');
    }
    await this.db.ensureReady();
    if (this.db.isStub) {
      return { ok: false, reason: 'db_stub' };
    }
    // Aggregate event counts
    const events = await this.db.query<{ type: string; cnt: string }>(
      `select type, count(*)::text as cnt from stripe_subscription_events group by type order by count(*) desc`
    );
    const lastEvent = await this.db.query<{ last_event_at: string }>(
      `select coalesce(max(created_at)::text,'') as last_event_at from stripe_subscription_events`
    );
    const subs = await this.db.query<{ active_count: string; canceled_count: string; past_due_count: string; total: string; pending_cancel_count: string }>(
      `select
         count(*) filter (where status='active')::text as active_count,
         count(*) filter (where status='canceled')::text as canceled_count,
         count(*) filter (where status='past_due')::text as past_due_count,
         count(*) filter (where cancel_at_period_end is true and status='active')::text as pending_cancel_count,
         count(*)::text as total
       from user_subscriptions`
    );
    const recent = await this.db.query<{ event_id: string; type: string; created_at: string }>(
      `select event_id, type, created_at::text from stripe_subscription_events order by created_at desc limit 5`
    );
    return {
      ok: true,
      last_event_at: lastEvent.rows[0]?.last_event_at || null,
      event_counts: events.rows.reduce<Record<string, number>>((acc, r) => { acc[r.type] = Number(r.cnt); return acc; }, {}),
      subscriptions: subs.rows[0] || {},
      recent_events: recent.rows,
    };
  }
}
