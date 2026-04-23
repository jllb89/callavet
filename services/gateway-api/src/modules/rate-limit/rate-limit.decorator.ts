import { SetMetadata } from '@nestjs/common';

export type EndpointRateLimitScope = 'user-or-ip' | 'user' | 'ip';

export type EndpointRateLimitOptions = {
  key: string;
  limit: number;
  windowMs: number;
  scope?: EndpointRateLimitScope;
};

export const ENDPOINT_RATE_LIMIT_METADATA = 'endpoint_rate_limit_metadata';

export const RateLimit = (options: EndpointRateLimitOptions) =>
  SetMetadata(ENDPOINT_RATE_LIMIT_METADATA, options);