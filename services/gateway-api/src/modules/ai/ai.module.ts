import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { ConfigModule } from '../config/config.module';
import { DbModule } from '../db/db.module';
import { EntitlementModule } from '../subscriptions/entitlement.module';
import { AiController } from './ai.controller';
import { AiService } from './ai.service';

@Module({
  imports: [AuthModule, ConfigModule, DbModule, EntitlementModule],
  controllers: [AiController],
  providers: [AiService],
  exports: [AiService],
})
export class AiModule {}
