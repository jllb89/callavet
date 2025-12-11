import { Body, Controller, Get, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';

@UseGuards(AuthGuard)
@Controller()
export class NotesController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}


  @Get('pets/:petId/care-plans')
  async listCarePlans(@Param('petId') petId: string, @Query('limit') limitStr?: string) {
    const limit = Math.min(Math.max(Number(limitStr ?? '100'), 1), 200);
    const items = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `select id, pet_id, created_by_ai, short_term, mid_term, long_term, created_at
           from care_plans
          where pet_id = $1
            and (
              exists (select 1 from pets p where p.id = care_plans.pet_id and p.user_id = auth.uid())
              or is_admin()
            )
          order by created_at desc
          limit $2`,
        [petId, limit]
      );
      if (process.env.DEV_DB_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.log('[plans:list] uid=%s pet=%s rows=%d', this.rc.claims?.sub, petId, rows.length);
      }
      return rows;
    });
    return { data: items };
  }

  @Post('pets/:petId/care-plans')
  async createCarePlan(
    @Param('petId') petId: string,
    @Body() body: { short_term?: string; mid_term?: string; long_term?: string; created_by_ai?: boolean }
  ) {
    const { short_term, mid_term, long_term } = body || {};
    const created_by_ai = !!(body && body.created_by_ai !== undefined ? body.created_by_ai : true);
    const row = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `insert into care_plans (id, pet_id, created_by_ai, short_term, mid_term, long_term, embedding, created_at)
         values (gen_random_uuid(), $1, $2, $3, $4, $5, NULL, now())
         returning id, pet_id, created_by_ai, short_term, mid_term, long_term, created_at`,
        [petId, created_by_ai, short_term || null, mid_term || null, long_term || null]
      );
      if (process.env.DEV_DB_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.log('[plans:create] uid=%s pet=%s ok=%s', this.rc.claims?.sub, petId, rows.length === 1);
      }
      return rows[0];
    });
    return row;
  }

  @Get('care-plans/:planId/items')
  async listCarePlanItems(@Param('planId') planId: string, @Query('limit') limitStr?: string) {
    const limit = Math.min(Math.max(Number(limitStr ?? '100'), 1), 500);
    const items = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `select id, care_plan_id, type, description, price_cents, fulfilled
           from care_plan_items
          where care_plan_id = $1
            and (
              exists (
                select 1 from care_plans cp
                join pets p on p.id = cp.pet_id
                where cp.id = care_plan_items.care_plan_id and p.user_id = auth.uid()
              )
              or is_admin()
            )
          order by id
          limit $2`,
        [planId, limit]
      );
      return rows;
    });
    return { data: items };
  }

  @Post('care-plans/:planId/items')
  async createCarePlanItem(
    @Param('planId') planId: string,
    @Body() body: { type: 'consult'|'vaccine'|'product'; description: string; price_cents?: number }
  ) {
    const { type, description } = body || ({} as any);
    const price = body?.price_cents ?? null;
    const row = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `insert into care_plan_items (id, care_plan_id, type, description, price_cents, fulfilled)
         select gen_random_uuid(), $1, $2, $3, $4, false
          where exists (
            select 1 from care_plans cp
            join pets p on p.id = cp.pet_id
            where cp.id = $1 and p.user_id = auth.uid()
          )
         returning id, care_plan_id, type, description, price_cents, fulfilled`,
        [planId, type, description, price]
      );
      return rows[0];
    });
    if (!row) return { ok: false, reason: 'not_owner_or_not_found' } as any;
    return row;
  }

  @Patch('care-plans/items/:itemId')
  async patchCarePlanItem(
    @Param('itemId') itemId: string,
    @Body() body: { description?: string; price_cents?: number; fulfilled?: boolean; type?: 'consult'|'vaccine'|'product' }
  ) {
    const fields: string[] = [];
    const args: any[] = [];
    let idx = 1;
    const add = (col: string, val: any) => { fields.push(`${col} = $${idx++}`); args.push(val); };
    if (body.description !== undefined) add('description', body.description);
    if (body.price_cents !== undefined) add('price_cents', body.price_cents);
    if (body.fulfilled !== undefined) add('fulfilled', body.fulfilled);
    if (body.type !== undefined) add('type', body.type);
    if (!fields.length) return { ok: false, reason: 'no_fields' } as any;
    const row = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `update care_plan_items set ${fields.join(', ')}
          where id = $${idx}
            and (
              exists (
                select 1 from care_plans cp
                join pets p on p.id = cp.pet_id
                where cp.id = care_plan_items.care_plan_id and p.user_id = auth.uid()
              )
              or is_admin()
            )
         returning id, care_plan_id, type, description, price_cents, fulfilled`,
        [...args, itemId]
      );
      return rows[0];
    });
    if (!row) return { ok: false, reason: 'not_found' } as any;
    return row;
  }
}
