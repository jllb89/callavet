import { Module } from '@nestjs/common';
import { MessagesController } from './messages.controller';
import { SessionMessagesController } from './session-messages.controller';
import { ChatMediaProcessingService } from './chat-media-processing.service';
import { AuthModule } from '../auth/auth.module';
import { DbModule } from '../db/db.module';

@Module({
  imports: [AuthModule, DbModule],
  controllers: [MessagesController, SessionMessagesController],
  providers: [ChatMediaProcessingService],
  exports: [ChatMediaProcessingService],
})
export class MessagesModule {}
