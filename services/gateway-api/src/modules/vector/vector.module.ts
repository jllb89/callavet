import { Module } from '@nestjs/common';
import { VectorController } from './vector.controller';
import { DbModule } from '../db/db.module';
import { AuthModule } from '../auth/auth.module';

// VectorModule exposes semantic vector search & upsert endpoints.
// Dependencies: DbModule (for queries), AuthModule (guards to inject claims for RLS).
@Module({
  imports: [DbModule, AuthModule],
  controllers: [VectorController],
})
export class VectorModule {}

