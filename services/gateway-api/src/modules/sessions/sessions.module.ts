import { Module } from '@nestjs/common';
import { SessionsController } from './sessions.controller';
import { DbModule } from '../db/db.module';
import { AuthModule } from '../auth/auth.module';

@Module({ imports: [DbModule, AuthModule], controllers: [SessionsController] })
export class SessionsModule {}
