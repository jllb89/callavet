import { Module } from '@nestjs/common';
import { ConfigModule as NestConfig } from '@nestjs/config';
import { z } from 'zod';

export const EnvSchema = z.object({
  NODE_ENV: z.enum(['development','staging','production']).default('development'),
  PORT: z.string().transform(v=>Number(v)).optional(),
  SUPABASE_JWT_SECRET: z.string().min(1).optional(),
  STRIPE_SECRET_KEY: z.string().min(1).optional(),
  DATABASE_URL: z.string().min(1).optional()
});

function validateEnv(config: Record<string, unknown>) {
  const result = EnvSchema.safeParse(config);
  if (!result.success) {
    // eslint-disable-next-line no-console
    console.warn('ENV validation warnings:', result.error.flatten());
  }
  return config;
}

@Module({
  imports: [
    NestConfig.forRoot({ isGlobal: true, validate: validateEnv })
  ],
})
export class ConfigModule {}
