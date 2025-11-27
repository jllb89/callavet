import { Module } from '@nestjs/common';
import { MessagesController } from './messages.controller';
import { SessionMessagesController } from './session-messages.controller';
import { AuthModule } from '../auth/auth.module';
import { DbModule } from '../db/db.module';

@Module({
  imports: [AuthModule, DbModule],
  controllers: [MessagesController, SessionMessagesController],
})
export class MessagesModule {}
