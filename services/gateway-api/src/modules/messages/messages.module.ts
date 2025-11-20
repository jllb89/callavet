import { Module } from '@nestjs/common';
import { MessagesController } from './messages.controller';
import { AuthModule } from '../auth/auth.module';

@Module({
  imports: [AuthModule],
  controllers: [MessagesController],
})
export class MessagesModule {}
