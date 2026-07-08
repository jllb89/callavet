import { Module } from '@nestjs/common';
import { AppointmentsController } from './appointments.controller';
import { DbModule } from '../db/db.module';
import { AuthModule } from '../auth/auth.module';
import { ConfigModule } from '../config/config.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { AppointmentSchedulingService } from './appointment-scheduling.service';

@Module({
  imports: [DbModule, AuthModule, ConfigModule, NotificationsModule],
  controllers: [AppointmentsController],
  providers: [AppointmentSchedulingService],
  exports: [AppointmentSchedulingService],
})
export class AppointmentsModule {}
