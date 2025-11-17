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
import { VectorModule } from './vector/vector.module';
import { KbModule } from './kb/kb.module';
import { SearchModule } from './search/search.module';
import { MeModule } from './me/me.module';

@Module({
  imports: [
    ConfigModule,
    DbModule,
    HealthModule,
    MetaModule,
    DocsModule,
    IdempotencyModule,
    AuthModule,
    BillingModule,
    SubscriptionsModule,
    SessionsModule,
    CentersModule,
    VectorModule,
    KbModule,
  SearchModule,
  MeModule,
  ],
})
export class AppModule {}
