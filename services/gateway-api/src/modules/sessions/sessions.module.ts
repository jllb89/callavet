import { Module } from '@nestjs/common';
import { SessionsController } from './sessions.controller';
import { DbModule } from '../db/db.module';
import { AuthModule } from '../auth/auth.module';
import { ConfigModule } from '../config/config.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { EntitlementModule } from '../subscriptions/entitlement.module';

@Module({ imports: [DbModule, AuthModule, ConfigModule, NotificationsModule, EntitlementModule], controllers: [SessionsController] })
export class SessionsModule {}
