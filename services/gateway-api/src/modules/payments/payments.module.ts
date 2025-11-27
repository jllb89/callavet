import { Module } from '@nestjs/common';
import { DbModule } from '../db/db.module';
import { PaymentsController } from './payments.controller';

@Module({ imports: [DbModule], controllers: [PaymentsController] })
export class PaymentsModule {}
