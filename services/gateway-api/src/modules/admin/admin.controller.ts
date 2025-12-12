import { BadRequestException, Controller, ForbiddenException, Get, Headers, Param, Query } from '@nestjs/common';
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
}
