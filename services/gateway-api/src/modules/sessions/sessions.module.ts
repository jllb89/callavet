import { Module } from '@nestjs/common';
import { SessionsController } from './sessions.controller';
import { DbModule } from '../db/db.module';
import { AuthModule } from '../auth/auth.module';
import { ConfigModule } from '../config/config.module';

@Module({ imports: [DbModule, AuthModule, ConfigModule], controllers: [SessionsController] })
export class SessionsModule {}
