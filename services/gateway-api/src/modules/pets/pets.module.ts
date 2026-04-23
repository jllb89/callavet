import { Module } from '@nestjs/common';
import { PetsController } from './pets.controller';
import { SchemaService } from './schema.service';
import { AuthModule } from '../auth/auth.module';
import { DbModule } from '../db/db.module';

@Module({
  imports: [AuthModule, DbModule],
  controllers: [PetsController],
  providers: [SchemaService],
})
export class PetsModule {}
