import { Controller, Get } from '@nestjs/common';
import { DbService } from './db.service';

@Controller('_db')
export class DbController {
  constructor(private readonly db: DbService) {}

  // GET /_db/status - expose stub mode and last error for diagnostics
  @Get('status')
  async status(){
    // Await initialization (including connectivity probe) before reporting
    try { await this.db.ensureReady(); } catch {} // swallow; details captured in lastError
    const s = this.db.status;
    // Augment with derived reason if pool missing and no explicit lastError
    if (s.stub && !s.lastError) {
      return { ...s, lastError: 'unknown_init_failure_or_deferred', hint: 'Enable DEV_DB_DEBUG=1 for verbose init logs. Check hasEnvUrl flag.' };
    }
    return s;
  }
}
