import { Module } from '@nestjs/common';
import { AppointmentsController } from './appointments.controller';
import { DbModule } from '../db/db.module';
import { AuthModule } from '../auth/auth.module';
import { ConfigModule } from '../config/config.module';

@Module({
  imports: [DbModule, AuthModule, ConfigModule],
  controllers: [AppointmentsController],
})
export class AppointmentsModule {}
