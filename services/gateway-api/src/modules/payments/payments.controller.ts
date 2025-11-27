import { Controller, Get, Param, Query } from '@nestjs/common';
import { DbService } from '../db/db.service';

@Controller()
export class PaymentsController {
  constructor(private readonly db: DbService) {}

  @Get('payments')
  async listPayments(@Query('limit') limitStr?: string) {
    const limit = Math.min(Math.max(Number(limitStr ?? '100'), 1), 200);
    const { rows } = await this.db.query(
      `select id, amount_cents, currency, status, created_at
         from payments
        where (user_id = auth.uid() or is_admin())
        order by created_at desc
        limit $1`,
      [limit]
    );
    return { data: rows };
  }

  @Get('payments/:id')
  async paymentDetail(@Param('id') id: string) {
    const { rows } = await this.db.query(
      `select id, amount_cents, currency, status, created_at, provider, provider_payment_id, session_id, subscription_id
         from payments
        where id = $1
          and (user_id = auth.uid() or is_admin())
        limit 1`,
      [id]
    );
    if (!rows[0]) return { ok: false, reason: 'not_found' } as any;
    return rows[0];
  }

  @Get('invoices')
  async listInvoices(@Query('limit') limitStr?: string) {
    const limit = Math.min(Math.max(Number(limitStr ?? '100'), 1), 200);
    const { rows } = await this.db.query(
      `select id, amount_cents, currency, status, issued_at
         from invoices
        where (user_id = auth.uid() or is_admin())
        order by issued_at desc
        limit $1`,
      [limit]
    );
    return { data: rows };
  }

  @Get('invoices/:id')
  async invoiceDetail(@Param('id') id: string) {
    const { rows } = await this.db.query(
      `select id, amount_cents, currency, status, issued_at, provider, provider_invoice_id, tax_rate, cfdi_uuid
         from invoices
        where id = $1
          and (user_id = auth.uid() or is_admin())
        limit 1`,
      [id]
    );
    if (!rows[0]) return { ok: false, reason: 'not_found' } as any;
    return rows[0];
  }
}
