import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { DbModule } from '../db/db.module';
import { RatingsController } from './ratings.controller';
import { VetsController } from './vets.controller';

@Module({
  imports: [DbModule, AuthModule],
  controllers: [VetsController, RatingsController],
})
export class VetsModule {}