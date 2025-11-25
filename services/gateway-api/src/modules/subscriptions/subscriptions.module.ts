import { Module } from '@nestjs/common';
import { PriceService } from './price.service';
import { StripeSyncService } from './stripe-sync.service';
import { SubscriptionsController } from './subscriptions.controller';
import { PlansController } from './plans.controller';
import { EntitlementsController } from './entitlements.controller';
import { DbModule } from '../db/db.module';
import { AuthModule } from '../auth/auth.module';

@Module({ imports: [DbModule, AuthModule], controllers: [SubscriptionsController, PlansController, EntitlementsController], providers: [PriceService, StripeSyncService] })
export class SubscriptionsModule {}
