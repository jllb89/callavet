import { Injectable, Logger } from '@nestjs/common';
import { DbService } from '../db/db.service';

// Skeleton service to reconcile Stripe Products/Prices into local subscription_plan_prices table.
// Extend later with scheduling or manual trigger endpoint.

interface StripePrice {
  id: string;
  product: string;
  recurring?: { interval: string };
  currency: string;
  active: boolean;
  metadata?: Record<string,string>;
}

interface StripeProduct {
  id: string;
  active: boolean;
  metadata?: Record<string,string>;
}

@Injectable()
export class StripeSyncService {
  private readonly log = new Logger('StripeSync');

  constructor(private readonly db: DbService) {}

  async sync(): Promise<{ updated: number; inserted: number; skipped: number }> {
    const sk = process.env.STRIPE_SECRET_KEY || '';
    if (!sk) {
      this.log.warn('No STRIPE_SECRET_KEY set; skipping sync');
      return { updated: 0, inserted: 0, skipped: 0 };
    }
    const Stripe = require('stripe');
    const stripe = new Stripe(sk, { apiVersion: '2024-06-20' });

    // Fetch prices & products (simple pagination for now)
    const prices: StripePrice[] = [];
    let hasMore = true; let startingAfter: string | undefined;
    while (hasMore) {
      const resp = await stripe.prices.list({ limit: 100, starting_after: startingAfter });
      prices.push(...resp.data as any);
      hasMore = resp.has_more;
      startingAfter = resp.data.length ? resp.data[resp.data.length - 1].id : undefined;
    }

    const productsMap = new Map<string, StripeProduct>();
    const prodResp = await stripe.products.list({ limit: 100 });
    for (const p of prodResp.data as any) productsMap.set(p.id, p);

    let updated = 0, inserted = 0, skipped = 0;

    for (const price of prices) {
      if (!price.active) { skipped++; continue; }
      const product = productsMap.get(price.product);
      if (!product || !product.active) { skipped++; continue; }
      const planCode = (price.metadata?.plan_code || product.metadata?.plan_code || '').trim();
      if (!planCode) { skipped++; continue; }
      const billing = price.recurring?.interval === 'year' ? 'year' : 'month';
      const currency = price.currency || 'usd';

      // Upsert logic
      const row = await this.db.query<any>(
        `select spp.id as spp_id, spp.stripe_price_id from subscription_plan_prices spp
          join subscription_plans sp on sp.id = spp.plan_id
         where sp.is_active and lower(sp.code)=lower($1)
           and spp.billing_period=$2 and lower(spp.currency)=lower($3)
         limit 1`, [planCode, billing, currency]
      );

      if (row.rows[0]) {
        if (row.rows[0].stripe_price_id !== price.id) {
          await this.db.query(`update subscription_plan_prices set stripe_price_id=$1, stripe_product_id=$2, updated_at=now() where id=$3`, [price.id, product.id, row.rows[0].spp_id]);
          updated++;
        } else {
          skipped++;
        }
      } else {
        // Need plan id
        const planRow = await this.db.query<any>(`select id from subscription_plans where is_active and lower(code)=lower($1) limit 1`, [planCode]);
        if (!planRow.rows[0]) { skipped++; continue; }
        await this.db.query(`insert into subscription_plan_prices(plan_id, stripe_product_id, stripe_price_id, billing_period, currency, is_active) values ($1,$2,$3,$4,$5,true)`,
          [planRow.rows[0].id, product.id, price.id, billing, currency]);
        inserted++;
      }
    }

    this.log.log(`Stripe sync complete: inserted=${inserted} updated=${updated} skipped=${skipped}`);
    return { updated, inserted, skipped };
  }
}
