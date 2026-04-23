import { Global, Module } from '@nestjs/common';
import { EndpointRateLimitGuard } from './endpoint-rate-limit.guard';

@Global()
@Module({
  providers: [EndpointRateLimitGuard],
  exports: [EndpointRateLimitGuard],
})
export class RateLimitModule {}