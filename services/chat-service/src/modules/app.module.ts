import { Module } from '@nestjs/common';
import { HealthModule } from './health/health.module';
import { ChatModule } from './chat/chat.module';

@Module({ imports: [HealthModule, ChatModule] })
export class AppModule {}
