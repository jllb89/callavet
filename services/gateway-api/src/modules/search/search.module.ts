import { Module } from '@nestjs/common';
import { DbModule } from '../db/db.module';
import { SearchController } from './search.controller';

@Module({
  imports: [DbModule],
  controllers: [SearchController],
})
export class SearchModule {}
