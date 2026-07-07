import { Module } from '@nestjs/common';
import { AdminController } from './admin.controller';
import { DbModule } from '../db/db.module';
import { MessagesModule } from '../messages/messages.module';

@Module({
  imports: [DbModule, MessagesModule],
  controllers: [AdminController],
})
export class AdminModule {}
