import { Module } from '@nestjs/common';
import { MessagesController } from './messages.controller';
import { SessionMessagesController } from './session-messages.controller';
import { AuthModule } from '../auth/auth.module';

@Module({
  imports: [AuthModule],
  controllers: [MessagesController, SessionMessagesController],
})
export class MessagesModule {}
