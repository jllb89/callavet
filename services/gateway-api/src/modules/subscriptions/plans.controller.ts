import { Controller, Get, Param } from '@nestjs/common';
import { DbService } from '../db/db.service';

// Public plans endpoints (no auth required)
@Controller('plans')
export class PlansController {
  constructor(private readonly db: DbService) {}

  @Get()
  async list() {
    if (this.db.isStub) {
      return { items: [] } as any;
    }
    const rows = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `select id, code, name, description, price_cents, currency, billing_period,
                included_chats, included_videos, pets_included_default, tax_rate, is_active
           from subscription_plans
          where is_active = true
          order by price_cents asc nulls last`
      );
      return rows.map((r: any) => ({
        id: r.id,
        code: r.code,
        name: r.name,
        description: r.description,
        price_cents: r.price_cents,
        currency: r.currency,
        billing_period: r.billing_period,
        included_chats: r.included_chats,
        included_videos: r.included_videos,
        pets_included_default: r.pets_included_default,
        tax_rate: r.tax_rate,
        is_active: r.is_active,
      }));
    });
    return { items: rows };
  }

  @Get(':code')
  async byCode(@Param('code') code: string) {
    if (this.db.isStub) {
      return { notFound: true } as any;
    }
    const row = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `select id, code, name, description, price_cents, currency, billing_period,
                included_chats, included_videos, pets_included_default, tax_rate, is_active
           from subscription_plans
          where lower(code) = lower($1)
          limit 1`,
        [code]
      );
      return rows[0];
    });
    if (!row) {
      const { HttpException } = require('@nestjs/common');
      throw new HttpException('Not Found', 404);
    }
    return {
      id: row.id,
      code: row.code,
      name: row.name,
      description: row.description,
      price_cents: row.price_cents,
      currency: row.currency,
      billing_period: row.billing_period,
      included_chats: row.included_chats,
      included_videos: row.included_videos,
      pets_included_default: row.pets_included_default,
      tax_rate: row.tax_rate,
      is_active: row.is_active,
    };
  }
}
