import { Module } from '@nestjs/common';
import { NotificationsController } from './notifications.controller';
import { AuthModule } from '../auth/auth.module';

@Module({
  imports: [AuthModule],
  controllers: [NotificationsController],
})
export class NotificationsModule {}
