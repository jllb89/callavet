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

async function bootstrap() {
  // Prefer IPv4 inside some container runtimes (e.g., Colima)
  try { dns.setDefaultResultOrder?.('ipv4first'); } catch {}
  const app = await NestFactory.create(AppModule, { logger: ['log','error','warn'] });
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
