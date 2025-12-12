import { Module } from '@nestjs/common';
import { ConfigModule } from './config/config.module';
import { HealthModule } from './health/health.module';
import { DbModule } from './db/db.module';
import { SubscriptionsModule } from './subscriptions/subscriptions.module';
import { SessionsModule } from './sessions/sessions.module';
import { CentersModule } from './centers/centers.module';
import { PaymentsModule } from './payments/payments.module';
import { AuthModule } from './auth/auth.module';
import { BillingModule } from './billing/billing.module';
import { MetaModule } from './meta/meta.module';
import { DocsModule } from './docs/docs.module';
import { IdempotencyModule } from './idempotency/idempotency.module';
import { VectorModule } from './vector/vector.module';
import { KbModule } from './kb/kb.module';
import { SearchModule } from './search/search.module';
import { MeModule } from './me/me.module';
import { PetsModule } from './pets/pets.module';
import { MessagesModule } from './messages/messages.module';
import { NotesModule } from './notes/notes.module';
import { FilesModule } from './files/files.module';
import { ImageCasesModule } from './image-cases/image-cases.module';
import { NotificationsModule } from './notifications/notifications.module';
import { AdminModule } from './admin/admin.module';
import { AppointmentsModule } from './appointments/appointments.module';

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
    PaymentsModule,
    VectorModule,
    KbModule,
  SearchModule,
  MeModule,
  PetsModule,
  MessagesModule,
  NotesModule,
  FilesModule,
  ImageCasesModule,
  NotificationsModule,
  AdminModule,
  AppointmentsModule,
  ],
})
export class AppModule {}
