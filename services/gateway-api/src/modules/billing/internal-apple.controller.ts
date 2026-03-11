import { Body, Controller, ForbiddenException, Headers, Post } from '@nestjs/common';
import { InternalAppleService } from './internal-apple.service';

@Controller('internal/apple')
export class InternalAppleController {
  constructor(private readonly svc: InternalAppleService) {}

  @Post('event')
  async ingest(
    @Headers('x-internal-secret') secret: string,
    @Body()
    body: {
      event_id?: string;
      event_type?: string;
      environment?: string;
      signed_payload?: string;
      payload?: any;
      original_transaction_id?: string;
      transaction_id?: string;
      product_id?: string;
      app_account_token?: string;
    }
  ) {
    if (!process.env.INTERNAL_APPLE_EVENT_SECRET || secret !== process.env.INTERNAL_APPLE_EVENT_SECRET) {
      throw new ForbiddenException('invalid secret');
    }

    try {
      const result = await this.svc.processEvent(body || {});
      return { ok: true, result };
    } catch (e: any) {
      console.error('[internal-apple] processEvent error', e?.message);
      return { ok: false, error: e?.message || 'unhandled_error' };
    }
  }
}
