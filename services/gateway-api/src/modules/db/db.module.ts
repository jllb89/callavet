import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { DbService } from './db.service';

@Module({ imports: [AuthModule], providers: [DbService], exports: [DbService] })
export class DbModule {}
