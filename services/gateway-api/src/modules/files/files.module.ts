import { Module } from '@nestjs/common';
import { FilesController } from './files.controller';
import { AuthModule } from '../auth/auth.module';
import { DbModule } from '../db/db.module';

@Module({
  imports: [AuthModule, DbModule],
  controllers: [FilesController],
})
export class FilesModule {}
