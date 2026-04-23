import { Module } from '@nestjs/common';
import { VideoController } from './video.controller';
import { ConfigModule } from '../config/config.module';

@Module({
  imports: [ConfigModule],
  controllers: [VideoController],
})
export class VideoModule {}