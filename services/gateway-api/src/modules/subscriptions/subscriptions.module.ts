import { Module } from '@nestjs/common';
import { SubscriptionsController } from './subscriptions.controller';
import { DbModule } from '../db/db.module';
import { AuthModule } from '../auth/auth.module';

@Module({ imports: [DbModule, AuthModule], controllers: [SubscriptionsController] })
export class SubscriptionsModule {}
