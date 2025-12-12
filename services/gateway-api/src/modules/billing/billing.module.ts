import { Module } from '@nestjs/common';
import { DbModule } from '../db/db.module';
import { InternalStripeController } from './internal-stripe.controller';
import { InternalBillingHealthController } from './internal-billing-health.controller';
import { InternalStripeService } from './internal-stripe.service';

@Module({
	imports: [DbModule],
	controllers: [InternalStripeController, InternalBillingHealthController],
	providers: [InternalStripeService],
	exports: [InternalStripeService],
})
export class BillingModule {}
