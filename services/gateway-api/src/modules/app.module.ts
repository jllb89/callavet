import { Module } from '@nestjs/common';
import { ConfigModule } from './config/config.module';
import { HealthModule } from './health/health.module';
import { DbModule } from './db/db.module';
import { SubscriptionsModule } from './subscriptions/subscriptions.module';
import { SessionsModule } from './sessions/sessions.module';
import { CentersModule } from './centers/centers.module';
import { AuthModule } from './auth/auth.module';
import { BillingModule } from './billing/billing.module';
import { MetaModule } from './meta/meta.module';
import { DocsModule } from './docs/docs.module';
import { IdempotencyModule } from './idempotency/idempotency.module';

@Module({
  imports: [ConfigModule, DbModule, HealthModule, MetaModule, DocsModule, IdempotencyModule, AuthModule, BillingModule, SubscriptionsModule, SessionsModule, CentersModule],
})
export class AppModule {}
