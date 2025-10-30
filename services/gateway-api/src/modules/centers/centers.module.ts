import { Module } from '@nestjs/common';
import { CentersController } from './centers.controller';
import { DbModule } from '../db/db.module';

@Module({ imports: [DbModule], controllers: [CentersController] })
export class CentersModule {}
