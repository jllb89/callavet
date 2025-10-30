import { CallHandler, ExecutionContext, Injectable, NestInterceptor } from '@nestjs/common';
import { Observable, of } from 'rxjs';
import { tap } from 'rxjs/operators';
import type { Response, Request } from 'express';
import { IdempotencyService } from './idempotency.service';

@Injectable()
export class IdempotencyInterceptor implements NestInterceptor {
  constructor(private readonly store: IdempotencyService) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<any> {
    const http = context.switchToHttp();
    const req = http.getRequest<Request>();
    const res = http.getResponse<Response>();
    const method = req.method.toUpperCase();

    // Only apply to mutating methods
    if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(method)) return next.handle();

    const key = req.header('Idempotency-Key');
    if (!key) return next.handle();

    const hit = this.store.get(key);
    if (hit) {
      // Replay stored response
      if (hit.headers) {
        for (const [h, v] of Object.entries(hit.headers)) res.setHeader(h, v);
      }
      res.status(hit.status);
      return of(hit.body);
    }

    // First request: run handler and store result
    return next.handle().pipe(
      tap((body) => {
        // Capture status after controller runs
        const status = res.statusCode || 200;
        // Capture a subset of headers (Location helpful for 201)
        const headers: Record<string, string> = {};
        const location = res.getHeader('location');
        if (location) headers['Location'] = String(location);
        this.store.set(key, status, body, headers);
      }),
    );
  }
}
