import { Module } from '@nestjs/common';
import { PetsController } from './pets.controller';
import { AuthModule } from '../auth/auth.module';

@Module({
  imports: [AuthModule],
  controllers: [PetsController],
})
export class PetsModule {}
