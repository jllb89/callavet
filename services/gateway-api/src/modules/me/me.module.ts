import { Module } from '@nestjs/common';
import { MeController } from './me.controller';
import { DbModule } from '../db/db.module';
import { AuthModule } from '../auth/auth.module';

@Module({
  imports: [DbModule, AuthModule],
  controllers: [MeController],
})
export class MeModule {}
