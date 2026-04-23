import { Module } from '@nestjs/common';
import { DbModule } from '../db/db.module';
import { ConfigModule } from '../config/config.module';
import { KbController } from './kb.controller';

@Module({
  imports: [DbModule, ConfigModule],
  controllers: [KbController],
})
export class KbModule {}
