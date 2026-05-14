import { Module, forwardRef } from '@nestjs/common';
import { ConfigModule as NestConfig } from '@nestjs/config';
import { z } from 'zod';
import { DbModule } from '../db/db.module';
import { ValidatorService } from './validator.service';
import { EnumService } from './enum.service';
import { VectorTargetService } from './vector-target.service';

export const EnvSchema = z.object({
  NODE_ENV: z.enum(['development','staging','production']).default('development'),
  PORT: z.string().transform(v=>Number(v)).optional(),
  SUPABASE_JWT_SECRET: z.string().min(1).optional(),
  STRIPE_SECRET_KEY: z.string().min(1).optional(),
  DATABASE_URL: z.string().min(1).optional(),
  LIVEKIT_URL: z.string().url().optional(),
  LIVEKIT_API_KEY: z.string().min(1).optional(),
  LIVEKIT_API_SECRET: z.string().min(1).optional(),
  LIVEKIT_WEBHOOK_SECRET: z.string().min(1).optional(),
  AI_PROVIDER: z.string().min(1).optional(),
  AI_PROVIDER_BASE_URL: z.string().url().optional(),
  AI_PROVIDER_API_KEY: z.string().min(1).optional(),
  AI_API_MODE: z.enum(['responses', 'chat_completions']).optional(),
  OPENAI_API_KEY: z.string().min(1).optional(),
  AI_MODEL: z.string().min(1).optional(),
  AI_EMBEDDING_MODEL: z.string().min(1).optional(),
  AI_REASONING_EFFORT: z.enum(['none', 'low', 'medium', 'high', 'xhigh']).optional(),
  AI_REQUEST_TIMEOUT_MS: z.string().regex(/^\d+$/).optional()
});

function validateEnv(config: Record<string, unknown>) {
  const result = EnvSchema.safeParse(config);
  if (!result.success) {
    // eslint-disable-next-line no-console
    console.warn('ENV validation warnings:', result.error.flatten());
  }
  return config;
}

/**
 * Shared services:
 * - ValidatorService: Centralized validation (UUID, email, phone, time)
 * - EnumService: Dynamic enum loading from database CHECK constraints
 * - VectorTargetService: Dynamic vector target configuration from database
 */
@Module({
  imports: [
    NestConfig.forRoot({ isGlobal: true, validate: validateEnv }),
    forwardRef(() => DbModule),
  ],
  providers: [ValidatorService, EnumService, VectorTargetService],
  exports: [ValidatorService, EnumService, VectorTargetService],
})
export class ConfigModule {}
