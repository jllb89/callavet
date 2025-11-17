/*
  Call a Vet - Gateway API (Nest-lite)
  Defaults:
  - PORT: 4000
  - Health: GET /health
  - Config via process.env (validated with Zod)
  - DB: pg Pool (optional in dev). If DATABASE_URL is missing, handlers run in stub mode.
*/
import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import dns from 'node:dns';
import { AppModule } from './modules/app.module';
import { ValidationPipe } from '@nestjs/common';
import { IdempotencyInterceptor } from './modules/idempotency/idempotency.interceptor';
import fs from 'node:fs';
import path from 'node:path';

// Force-load root .env (merge, do not override existing) — Turbo may not propagate shell env vars
(() => {
  try {
    const candidate = path.resolve(__dirname, '../../..', '.env');
    if (fs.existsSync(candidate)) {
      const raw = fs.readFileSync(candidate, 'utf8');
      for (const line of raw.split(/\r?\n/)) {
        const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*?)=(.*)$/);
        if (!m) continue;
        const [_, key, val] = m;
        if (!process.env[key]) {
          // Strip surrounding quotes if present
          const unquoted = val.replace(/^[\'"](.*)[\'"]$/,'$1');
          process.env[key] = unquoted;
        }
      }
      // eslint-disable-next-line no-console
      console.log('[env] Loaded .env (merged). DATABASE_URL present:', !!process.env.DATABASE_URL);
    }
  } catch (e) {
    // eslint-disable-next-line no-console
    console.warn('[env] .env merge load skipped:', (e as any)?.message || e);
  }
})();

async function bootstrap() {
  // Prefer IPv4 inside some container runtimes (e.g., Colima)
  try { dns.setDefaultResultOrder?.('ipv4first'); } catch {}
  const app = await NestFactory.create(AppModule, { logger: ['log','error','warn'] });
  if (!process.env.DATABASE_URL) {
    // eslint-disable-next-line no-console
    console.error('[env] DATABASE_URL still missing after fallback load -> running in stub mode.');
  } else if (process.env.DEV_DB_DEBUG === '1') {
    // Mask password when logging
    try {
      const u = new URL(process.env.DATABASE_URL);
      const masked = `${u.protocol}//${u.username}:****@${u.hostname}:${u.port}${u.pathname}${u.search}`;
      // eslint-disable-next-line no-console
      console.log('[env] DATABASE_URL=', masked);
    } catch {
      // eslint-disable-next-line no-console
      console.log('[env] DATABASE_URL set (unable to parse for masking)');
    }
  }
  app.enableCors();
  app.useGlobalPipes(new ValidationPipe({ transform: true }));
  // Global idempotency for mutation endpoints (simple in-memory for now)
  app.useGlobalInterceptors(app.get(IdempotencyInterceptor));
  const port = process.env.PORT ? Number(process.env.PORT) : 4000;
  await app.listen(port, '0.0.0.0');
  // eslint-disable-next-line no-console
  console.log(`Gateway API listening on :${port}`);
}
bootstrap();
