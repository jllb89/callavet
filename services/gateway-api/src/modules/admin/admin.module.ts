import { Module } from '@nestjs/common';
import { AdminController } from './admin.controller';
import { DbModule } from '../db/db.module';

@Module({
  imports: [DbModule],
  controllers: [AdminController],
})
export class AdminModule {}
