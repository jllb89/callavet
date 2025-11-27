import { Controller, Get, Param, Query, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';

@UseGuards(AuthGuard)
@Controller()
export class PaymentsController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

  @Get('payments')
  async listPayments(@Query('limit') limitStr?: string) {
    const limit = Math.min(Math.max(Number(limitStr ?? '100'), 1), 200);
    const res = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `select id, amount_cents, currency, status, created_at
           from payments
          where (user_id = auth.uid() or is_admin())
          order by created_at desc
          limit $1`,
        [limit]
      );
      if (process.env.DEV_DB_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.log('[payments:list] uid=%s rows=%d limit=%d', this.rc.claims?.sub, rows.length, limit);
      }
      return rows;
    });
    return { data: res };
  }

  @Get('payments/:id')
  async paymentDetail(@Param('id') id: string) {
    const row = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `select id, amount_cents, currency, status, created_at, provider, provider_payment_id, session_id, subscription_id
           from payments
          where id = $1
            and (user_id = auth.uid() or is_admin())
          limit 1`,
        [id]
      );
      if (process.env.DEV_DB_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.log('[payments:detail] uid=%s id=%s found=%s', this.rc.claims?.sub, id, rows.length === 1);
      }
      return rows[0];
    });
    if (!row) return { ok: false, reason: 'not_found' } as any;
    return row;
  }

  @Get('invoices')
  async listInvoices(@Query('limit') limitStr?: string) {
    const limit = Math.min(Math.max(Number(limitStr ?? '100'), 1), 200);
    const res = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `select id, amount_cents, currency, status, issued_at
           from invoices
          where (user_id = auth.uid() or is_admin())
          order by issued_at desc
          limit $1`,
        [limit]
      );
      if (process.env.DEV_DB_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.log('[invoices:list] uid=%s rows=%d limit=%d', this.rc.claims?.sub, rows.length, limit);
      }
      return rows;
    });
    return { data: res };
  }

  @Get('invoices/:id')
  async invoiceDetail(@Param('id') id: string) {
    const row = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `select id, amount_cents, currency, status, issued_at, provider, provider_invoice_id, tax_rate, cfdi_uuid
           from invoices
          where id = $1
            and (user_id = auth.uid() or is_admin())
          limit 1`,
        [id]
      );
      if (process.env.DEV_DB_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.log('[invoices:detail] uid=%s id=%s found=%s', this.rc.claims?.sub, id, rows.length === 1);
      }
      return rows[0];
    });
    if (!row) return { ok: false, reason: 'not_found' } as any;
    return row;
  }
}
