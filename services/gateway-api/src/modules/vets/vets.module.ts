import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { DbModule } from '../db/db.module';
import { ConfigModule } from '../config/config.module';
import { RatingsController } from './ratings.controller';
import { VetsController } from './vets.controller';

@Module({
  imports: [DbModule, AuthModule, ConfigModule],
  controllers: [VetsController, RatingsController],
})
export class VetsModule {}