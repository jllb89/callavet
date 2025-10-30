/*
  Chat Service - Nest WebSocket gateway
  Namespace: /chat
  Events: join, leave, typing, message:new, presence
*/
import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './modules/app.module';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { logger: ['log','error','warn'] });
  const port = process.env.PORT ? Number(process.env.PORT) : 4100;
  await app.listen(port, '0.0.0.0');
  // eslint-disable-next-line no-console
  console.log(`Chat Service listening on :${port}`);
}
bootstrap();
