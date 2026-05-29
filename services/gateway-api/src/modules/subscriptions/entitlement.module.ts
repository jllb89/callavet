import { Module } from '@nestjs/common';
import { DbModule } from '../db/db.module';
import { EntitlementService } from './entitlement.service';

@Module({
  imports: [DbModule],
  providers: [EntitlementService],
  exports: [EntitlementService],
})
export class EntitlementModule {}