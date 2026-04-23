import { Module } from '@nestjs/common';
import { VectorController } from './vector.controller';
import { DbModule } from '../db/db.module';
import { AuthModule } from '../auth/auth.module';
import { ConfigModule } from '../config/config.module';

// VectorModule exposes semantic vector search & upsert endpoints.
// Dependencies: DbModule (for queries), AuthModule (guards to inject claims for RLS), ConfigModule (for VectorTargetService).
@Module({
  imports: [DbModule, AuthModule, ConfigModule],
  controllers: [VectorController],
})
export class VectorModule {}

