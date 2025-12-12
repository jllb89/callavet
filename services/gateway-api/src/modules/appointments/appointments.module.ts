import { Module } from '@nestjs/common';
import { AppointmentsController } from './appointments.controller';
import { DbModule } from '../db/db.module';
import { AuthModule } from '../auth/auth.module';

@Module({
  imports: [DbModule, AuthModule],
  controllers: [AppointmentsController],
})
export class AppointmentsModule {}
