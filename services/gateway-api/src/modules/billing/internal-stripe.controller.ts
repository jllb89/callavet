import { Controller, Post, Headers, Body, ForbiddenException } from '@nestjs/common';
import { InternalStripeService } from './internal-stripe.service';

@Controller('internal/stripe')
export class InternalStripeController {
  constructor(private readonly svc: InternalStripeService) {}

  @Post('event')
  async ingest(
    @Headers('x-internal-secret') secret: string,
    @Body() body: { id: string; type: string; data: any }
  ) {
    if (!process.env.INTERNAL_STRIPE_EVENT_SECRET || secret !== process.env.INTERNAL_STRIPE_EVENT_SECRET) {
      throw new ForbiddenException('invalid secret');
    }
    if (!body || !body.id || !body.type) {
      return { ok: false, reason: 'invalid_payload' };
    }
    const result = await this.svc.processEvent(body);
    return { ok: true, event: body.type, result };
  }
}
