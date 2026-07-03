import { Module } from '@nestjs/common';
import { VideoController } from './video.controller';
import { ConfigModule } from '../config/config.module';
import { DbModule } from '../db/db.module';
import { EntitlementModule } from '../subscriptions/entitlement.module';
import { AiModule } from '../ai/ai.module';
import { LiveKitService } from './livekit.service';

@Module({
  imports: [ConfigModule, DbModule, EntitlementModule, AiModule],
  controllers: [VideoController],
  providers: [LiveKitService],
  exports: [LiveKitService],
})
export class VideoModule {}