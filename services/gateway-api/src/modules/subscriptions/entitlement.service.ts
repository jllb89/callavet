import { Injectable } from '@nestjs/common';
import { DbService } from '../db/db.service';

export type EntitlementKind = 'chat' | 'video';
export type TxQuery = <R = any>(sql: string, args?: any[]) => Promise<{ rows: R[] }>;

export type EntitlementUsageSnapshot = {
  included_chats: number;
  consumed_chats: number;
  included_videos: number;
  consumed_videos: number;
  overage_chats?: number;
  overage_videos?: number;
  period_start: string;
  period_end: string;
};

@Injectable()
export class EntitlementService {
  constructor(private readonly db: DbService) {}

  activeSubscriptionSql(alias = 'us') {
    return `${alias}.status = ANY(ARRAY['active','trialing']::text[])
      and now() >= ${alias}.current_period_start
      and now() < ${alias}.current_period_end`;
  }

  async activeSubscriptionIdForAuthUser(q: TxQuery, options: { forUpdate?: boolean } = {}) {
    const { rows } = await q<{ id: string }>(
      `select us.id
         from user_subscriptions us
        where us.user_id = auth.uid()
          and ${this.activeSubscriptionSql('us')}
        order by us.current_period_end desc nulls last
        limit 1${options.forUpdate ? ' for update' : ''}`
    );
    return rows[0]?.id || null;
  }

  async currentUsageForAuthUser(q: TxQuery): Promise<EntitlementUsageSnapshot | null> {
    const subscriptionId = await this.activeSubscriptionIdForAuthUser(q);
    if (!subscriptionId) return null;
    const { rows } = await q<any>(`select * from fn_current_usage($1::uuid)`, [subscriptionId]);
    return this.toUsageSnapshot(rows[0] || null);
  }

  async checkServiceAccessForUser(userId: string, serviceType: EntitlementKind, q?: TxQuery) {
    const query = q || this.db.query.bind(this.db);
    const { rows } = await query<any>(
      `select us.id as subscription_id,
              p.code as plan_code,
              coalesce(su.included_chats, p.included_chats, 0)::int as included_chats,
              coalesce(su.included_videos, p.included_videos, 0)::int as included_videos,
              coalesce(su.consumed_chats, 0)::int as consumed_chats,
              coalesce(su.consumed_videos, 0)::int as consumed_videos,
              coalesce(oc.remaining_units, 0)::int as overage_remaining
         from user_subscriptions us
         join subscription_plans p on p.id = us.plan_id
    left join subscription_usage su
           on su.subscription_id = us.id
          and su.period_start = us.current_period_start
          and su.period_end = us.current_period_end
    left join lateral (
              select sum(oc.remaining_units)::int as remaining_units
                from overage_credits oc
                join overage_items oi on oi.id = oc.overage_item_id
               where oc.user_id = us.user_id
                 and coalesce(oi.metadata->>'type', '') = $2
                 and oc.remaining_units > 0
                 and (oc.expires_at is null or oc.expires_at > now())
           ) oc on true
        where us.user_id = $1::uuid
          and ${this.activeSubscriptionSql('us')}
        order by us.current_period_end desc nulls last
        limit 1`,
      [userId, serviceType]
    );
    const row = rows[0];
    if (!row) return { ok: true, serviceType, canUse: false, reason: 'no_active_subscription' };

    const included = serviceType === 'chat' ? Number(row.included_chats || 0) : Number(row.included_videos || 0);
    const consumed = serviceType === 'chat' ? Number(row.consumed_chats || 0) : Number(row.consumed_videos || 0);
    const overageRemaining = Number(row.overage_remaining || 0);
    const includedRemaining = Math.max(included - consumed, 0);
    const canUse = includedRemaining > 0 || overageRemaining > 0;
    return {
      ok: true,
      serviceType,
      canUse,
      reason: canUse ? 'available' : `no_${serviceType}_entitlement_left`,
      subscriptionId: row.subscription_id,
      planCode: row.plan_code,
      included,
      consumed,
      overageRemaining,
      remaining: includedRemaining + overageRemaining,
    };
  }

  async reserveForAuthUser(q: TxQuery, serviceType: EntitlementKind, sessionId: string) {
    const fn = serviceType === 'video' ? 'fn_reserve_video' : 'fn_reserve_chat';
    const { rows } = await q<{ ok: boolean; subscription_id: string | null; consumption_id: string | null; msg: string | null }>(
      `select * from ${fn}(auth.uid(), trim($1)::uuid)`,
      [sessionId]
    );
    return rows[0] || null;
  }

  async reserveForUser(q: TxQuery, serviceType: EntitlementKind, userId: string, sessionId: string) {
    const fn = serviceType === 'video' ? 'fn_reserve_video' : 'fn_reserve_chat';
    const { rows } = await q<{ ok: boolean; subscription_id: string | null; consumption_id: string | null; msg: string | null }>(
      `select * from ${fn}($1::uuid, $2::uuid)`,
      [userId, sessionId]
    );
    return rows[0] || null;
  }

  private toUsageSnapshot(row: any): EntitlementUsageSnapshot | null {
    if (!row) return null;
    return {
      included_chats: Number(row.included_chats || 0),
      consumed_chats: Number(row.consumed_chats || 0),
      included_videos: Number(row.included_videos || 0),
      consumed_videos: Number(row.consumed_videos || 0),
      overage_chats: Number(row.overage_chats || 0),
      overage_videos: Number(row.overage_videos || 0),
      period_start: row.period_start,
      period_end: row.period_end,
    };
  }
}