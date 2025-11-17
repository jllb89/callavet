import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { DbService } from './db.service';
import { DbController } from './db.controller';

@Module({ imports: [AuthModule], providers: [DbService], controllers: [DbController], exports: [DbService] })
export class DbModule {}
