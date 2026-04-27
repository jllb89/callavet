import { Module } from '@nestjs/common';
import { VideoController } from './video.controller';
import { ConfigModule } from '../config/config.module';
import { DbModule } from '../db/db.module';
import { LiveKitService } from './livekit.service';

@Module({
  imports: [ConfigModule, DbModule],
  controllers: [VideoController],
  providers: [LiveKitService],
})
export class VideoModule {}