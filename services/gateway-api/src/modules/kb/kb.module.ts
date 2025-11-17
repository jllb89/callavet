import { Module } from '@nestjs/common';
import { DbModule } from '../db/db.module';
import { KbController } from './kb.controller';

@Module({
  imports: [DbModule],
  controllers: [KbController],
})
export class KbModule {}
