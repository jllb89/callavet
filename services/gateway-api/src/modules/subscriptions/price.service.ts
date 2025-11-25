import { Injectable } from '@nestjs/common';
import { DbService } from '../db/db.service';

interface CachedPriceKey {
  planCode: string;
  billingPeriod: string;
  currency: string;
}

interface PriceCacheEntry {
  stripePriceId: string | null;
  stripeProductId: string | null;
  fetchedAt: number;
}

@Injectable()
export class PriceService {
  private cache = new Map<string, PriceCacheEntry>();
  private ttlMs = 60_000; // 60s basic TTL; adjust later or make configurable

  constructor(private readonly db: DbService) {}

  private key(k: CachedPriceKey): string {
    return `${k.planCode.toLowerCase()}|${k.billingPeriod}|${k.currency.toLowerCase()}`;
  }

  async getActivePrice(planCode: string, billingPeriod: string = 'month', currency: string = 'usd'): Promise<PriceCacheEntry> {
    const k = this.key({ planCode, billingPeriod, currency });
    const existing = this.cache.get(k);
    const now = Date.now();
    if (existing && (now - existing.fetchedAt) < this.ttlMs) {
      return existing;
    }

    // Query flexible table first (subscription_plan_prices)
    // Fallback to column on subscription_plans.
    const row = await this.db.query<any>(
      `with plan as (
         select id, code, stripe_product_id, stripe_price_id
           from subscription_plans
          where is_active and lower(code)=lower($1)
          limit 1
       )
       select p.id as plan_id,
              p.code,
              coalesce(spp.stripe_product_id, p.stripe_product_id) as stripe_product_id,
              coalesce(spp.stripe_price_id, p.stripe_price_id)   as stripe_price_id
         from plan p
         left join subscription_plan_prices spp
           on spp.plan_id = p.id
          and spp.is_active
          and spp.billing_period = $2
          and lower(spp.currency) = lower($3)
         limit 1`,
      [planCode, billingPeriod, currency]
    );

    const stripePriceId = row.rows[0]?.stripe_price_id || null;
    const stripeProductId = row.rows[0]?.stripe_product_id || null;

    const entry: PriceCacheEntry = { stripePriceId, stripeProductId, fetchedAt: now };
    this.cache.set(k, entry);
    return entry;
  }

  clearCache() { this.cache.clear(); }
}
