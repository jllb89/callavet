import {
  CanActivate,
  ExecutionContext,
  HttpException,
  HttpStatus,
  Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import {
  ENDPOINT_RATE_LIMIT_METADATA,
  EndpointRateLimitOptions,
} from './rate-limit.decorator';

type Bucket = {
  count: number;
  resetAt: number;
};

@Injectable()
export class EndpointRateLimitGuard implements CanActivate {
  private readonly buckets = new Map<string, Bucket>();

  constructor(private readonly reflector: Reflector) {}

  private extractIp(req: any): string {
    const forwarded = req?.headers?.['x-forwarded-for'];
    if (typeof forwarded === 'string' && forwarded.trim()) {
      return forwarded.split(',')[0]?.trim() || 'unknown';
    }
    if (Array.isArray(forwarded) && forwarded[0]) {
      return forwarded[0].split(',')[0]?.trim() || 'unknown';
    }
    return (
      req?.ip?.toString?.() ||
      req?.socket?.remoteAddress?.toString?.().replace('::ffff:', '') ||
      'unknown'
    );
  }

  private prune(now: number) {
    if (this.buckets.size < 5000) return;
    for (const [key, value] of this.buckets.entries()) {
      if (value.resetAt <= now) this.buckets.delete(key);
    }
  }

  private subjectFor(req: any, options: EndpointRateLimitOptions): string {
    const userId = req?.authClaims?.sub?.toString?.() || '';
    const ip = this.extractIp(req);
    switch (options.scope || 'user-or-ip') {
      case 'user':
        return userId || `anon:${ip}`;
      case 'ip':
        return `ip:${ip}`;
      default:
        return userId ? `user:${userId}` : `ip:${ip}`;
    }
  }

  canActivate(context: ExecutionContext): boolean {
    const options = this.reflector.getAllAndOverride<EndpointRateLimitOptions>(
      ENDPOINT_RATE_LIMIT_METADATA,
      [context.getHandler(), context.getClass()]
    );
    if (!options) return true;

    const req = context.switchToHttp().getRequest<any>();
    const res = context.switchToHttp().getResponse<any>();
    const now = Date.now();
    this.prune(now);

    const subject = this.subjectFor(req, options);
    const bucketKey = `${options.key}:${subject}`;
    const current = this.buckets.get(bucketKey);

    let next: Bucket;
    if (!current || current.resetAt <= now) {
      next = { count: 1, resetAt: now + options.windowMs };
    } else if (current.count >= options.limit) {
      const retryAfterSeconds = Math.max(1, Math.ceil((current.resetAt - now) / 1000));
      if (typeof res?.setHeader === 'function') {
        res.setHeader('retry-after', String(retryAfterSeconds));
        res.setHeader('x-ratelimit-limit', String(options.limit));
        res.setHeader('x-ratelimit-remaining', '0');
        res.setHeader('x-ratelimit-reset', String(current.resetAt));
      }
      throw new HttpException({
        ok: false,
        code: 'rate_limited',
        message: `Too many requests for ${options.key}`,
        retryAfterSeconds,
      }, HttpStatus.TOO_MANY_REQUESTS);
    } else {
      next = { count: current.count + 1, resetAt: current.resetAt };
    }

    this.buckets.set(bucketKey, next);
    if (typeof res?.setHeader === 'function') {
      res.setHeader('x-ratelimit-limit', String(options.limit));
      res.setHeader('x-ratelimit-remaining', String(Math.max(0, options.limit - next.count)));
      res.setHeader('x-ratelimit-reset', String(next.resetAt));
    }

    return true;
  }
}