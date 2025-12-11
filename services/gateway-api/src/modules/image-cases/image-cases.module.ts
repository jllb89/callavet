import { Module } from '@nestjs/common';
import { ImageCasesController } from './image-cases.controller';
import { AuthModule } from '../auth/auth.module';
import { DbModule } from '../db/db.module';

@Module({
  imports: [AuthModule, DbModule],
  controllers: [ImageCasesController],
})
export class ImageCasesModule {}
