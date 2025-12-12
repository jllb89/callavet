import { Module } from '@nestjs/common';
import { NotificationsController } from './notifications.controller';
import { AuthModule } from '../auth/auth.module';
import { NotificationsService } from './notifications.service';

@Module({
  imports: [AuthModule],
  controllers: [NotificationsController],
  providers: [NotificationsService],
})
export class NotificationsModule {}
