import { Controller, Post, Headers, ForbiddenException } from '@nestjs/common';
import { StripeSyncService } from './stripe-sync.service';

@Controller('admin/pricing')
export class AdminPricingController {
  constructor(private readonly sync: StripeSyncService) {}

  @Post('sync')
  async syncPricing(@Headers('x-admin-secret') secret: string) {
    const expected = process.env.ADMIN_PRICING_SYNC_SECRET;
    if (!expected || secret !== expected) throw new ForbiddenException('invalid admin secret');
    try {
      const result = await this.sync.sync();
      return { ok: true, action: 'pricing_sync', ...result };
    } catch (e: any) {
      return { ok: false, reason: 'sync_failed', error: e?.message || 'unhandled_error' };
    }
  }
}
