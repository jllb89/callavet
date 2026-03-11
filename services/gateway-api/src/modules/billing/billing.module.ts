import { Module } from '@nestjs/common';
import { DbModule } from '../db/db.module';
import { InternalStripeController } from './internal-stripe.controller';
import { InternalAppleController } from './internal-apple.controller';
import { InternalBillingHealthController } from './internal-billing-health.controller';
import { InternalStripeService } from './internal-stripe.service';
import { InternalAppleService } from './internal-apple.service';

@Module({
	imports: [DbModule],
	controllers: [InternalStripeController, InternalAppleController, InternalBillingHealthController],
	providers: [InternalStripeService, InternalAppleService],
	exports: [InternalStripeService, InternalAppleService],
})
export class BillingModule {}
