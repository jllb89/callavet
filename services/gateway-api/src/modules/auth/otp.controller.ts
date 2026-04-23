import {
  BadRequestException,
  Body,
  Controller,
  HttpException,
  HttpStatus,
  Post,
  Req,
  UnauthorizedException,
  UseGuards,
} from '@nestjs/common';
import { DbService } from '../db/db.service';
import { RequestContext } from './request-context.service';
import { EndpointRateLimitGuard } from '../rate-limit/endpoint-rate-limit.guard';
import { RateLimit } from '../rate-limit/rate-limit.decorator';

type OtpChannel = 'sms' | 'email';

type SendOtpBody = {
  channel: OtpChannel;
  phone?: string;
  email?: string;
  shouldCreateUser?: boolean;
};

type VerifyAttemptBody = {
  channel: OtpChannel;
  phone?: string;
  email?: string;
  success: boolean;
};

type VerifyLockBody = {
  channel: OtpChannel;
  phone?: string;
  email?: string;
};

type EmailConfirmBody = {
  email: string;
};

@Controller('auth/otp')
export class OtpController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

  private getSupabaseAuthConfig() {
    const supabaseUrl = (process.env.SUPABASE_URL || '').trim();
    const authKey =
      (process.env.SUPABASE_ANON_KEY || '').trim() ||
      (process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();

    if (!supabaseUrl || !authKey) {
      throw new HttpException(
        {
          ok: false,
          code: 'server_config_missing',
          message:
            'missing SUPABASE_URL and SUPABASE_ANON_KEY (or SUPABASE_SERVICE_ROLE_KEY) in gateway env.',
        },
        HttpStatus.INTERNAL_SERVER_ERROR,
      );
    }

    return { supabaseUrl, authKey };
  }

  private extractIp(req: any): string {
    const forwarded = req?.headers?.['x-forwarded-for'];
    if (typeof forwarded === 'string' && forwarded.trim().length > 0) {
      return forwarded.split(',')[0]?.trim() || 'unknown';
    }
    if (Array.isArray(forwarded) && forwarded.length > 0) {
      return forwarded[0]?.split(',')[0]?.trim() || 'unknown';
    }
    return req?.ip?.toString?.() || 'unknown';
  }

  private normalizePhone(input: string): { e164: string; identifier: string } {
    const compact = input.replace(/[^0-9+]/g, '');
    if (!compact) {
      throw new BadRequestException('phone is required');
    }
    const e164 = compact.startsWith('+')
      ? compact
      : `+${compact.replace(/[^0-9]/g, '')}`;
    const digits = e164.replace(/[^0-9]/g, '');
    if (digits.length < 8 || digits.length > 15) {
      throw new BadRequestException('phone must be valid E.164');
    }
    return { e164, identifier: `sms:${digits}` };
  }

  private normalizeEmail(input: string): { email: string; identifier: string } {
    const email = input.trim().toLowerCase();
    const ok = /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email);
    if (!ok) throw new BadRequestException('email format is invalid');
    return { email, identifier: `email:${email}` };
  }

  private async postSupabaseOtp(payload: any) {
    const { supabaseUrl, authKey } = this.getSupabaseAuthConfig();
    const response = await fetch(`${supabaseUrl}/auth/v1/otp`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        apikey: authKey,
        Authorization: `Bearer ${authKey}`,
      },
      body: JSON.stringify(payload),
    });

    const text = await response.text();
    let json: any = null;
    if (text) {
      try {
        json = JSON.parse(text);
      } catch {
        json = null;
      }
    }

    if (!response.ok) {
      const message =
        json?.msg ||
        json?.error_description ||
        json?.error ||
        'No se pudo enviar el código.';
      throw new HttpException(
        {
          ok: false,
          code: 'supabase_otp_error',
          message,
        },
        response.status >= 400 && response.status < 500
          ? response.status
          : HttpStatus.BAD_GATEWAY,
      );
    }
  }

  private async updateSupabaseUserWithBearer(
    userBearerToken: string,
    payload: Record<string, any>,
  ) {
    const { supabaseUrl, authKey } = this.getSupabaseAuthConfig();
    const response = await fetch(`${supabaseUrl}/auth/v1/user`, {
      method: 'PUT',
      headers: {
        'Content-Type': 'application/json',
        apikey: authKey,
        Authorization: `Bearer ${userBearerToken}`,
      },
      body: JSON.stringify(payload),
    });

    const text = await response.text();
    let json: any = null;
    if (text) {
      try {
        json = JSON.parse(text);
      } catch {
        json = null;
      }
    }

    if (!response.ok) {
      const message =
        json?.msg ||
        json?.error_description ||
        json?.error ||
        'No se pudo solicitar confirmación de email.';
      throw new HttpException(
        {
          ok: false,
          code: 'supabase_user_update_error',
          message,
        },
        response.status >= 400 && response.status < 500
          ? response.status
          : HttpStatus.BAD_GATEWAY,
      );
    }

    return json;
  }

  @Post('send')
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'auth.otp.send', limit: 5, windowMs: 60_000, scope: 'ip' })
  async sendOtp(@Body() body: SendOtpBody, @Req() req: any) {
    const channel = body.channel;
    if (channel !== 'sms' && channel !== 'email') {
      throw new BadRequestException('channel must be sms or email');
    }

    const ipAddress = this.extractIp(req);
    let destination: string;
    let identifier: string;
    if (channel === 'sms') {
      if (!body.phone) throw new BadRequestException('phone is required for sms channel');
      const normalized = this.normalizePhone(body.phone);
      destination = normalized.e164;
      identifier = normalized.identifier;
    } else {
      if (!body.email) throw new BadRequestException('email is required for email channel');
      const normalized = this.normalizeEmail(body.email);
      destination = normalized.email;
      identifier = normalized.identifier;
    }

    const preflight = await this.db.query<{
      allowed: boolean;
      code: string;
      message: string;
      retry_after_seconds: number | null;
    }>(
      `select allowed, code, message, retry_after_seconds
       from public.otp_guard_check_send($1, $2, $3)`,
      [identifier, channel, ipAddress],
    );

    const guard = preflight.rows[0];
    if (!guard || !guard.allowed) {
      throw new HttpException(
        {
          ok: false,
          code: guard?.code || 'otp_send_blocked',
          message: guard?.message || 'Demasiados intentos. Intenta más tarde.',
          retryAfterSeconds: guard?.retry_after_seconds || null,
        },
        HttpStatus.TOO_MANY_REQUESTS,
      );
    }

    await this.postSupabaseOtp(
      channel === 'sms'
        ? {
            phone: destination,
            create_user: body.shouldCreateUser ?? false,
            channel: 'sms',
          }
        : {
            email: destination,
            create_user: body.shouldCreateUser ?? false,
            should_create_user: body.shouldCreateUser ?? false,
          },
    );

    await this.db.query(
      `select public.otp_guard_record_send($1, $2, $3)`,
      [identifier, channel, ipAddress],
    );

    return {
      ok: true,
      cooldownSeconds: 60,
      message:
        channel === 'sms'
          ? 'Código enviado por SMS.'
          : 'Código enviado a tu correo.',
    };
  }

  @Post('verify-lock')
  async verifyLock(@Body() body: VerifyLockBody) {
    const channel = body.channel;
    if (channel !== 'sms' && channel !== 'email') {
      throw new BadRequestException('channel must be sms or email');
    }

    const identifier =
      channel === 'sms'
        ? this.normalizePhone(body.phone || '').identifier
        : this.normalizeEmail(body.email || '').identifier;

    const result = await this.db.query<{
      allowed: boolean;
      code: string;
      message: string;
      retry_after_seconds: number | null;
    }>(
      `select allowed, code, message, retry_after_seconds
       from public.otp_guard_check_verify_lock($1, $2)`,
      [identifier, channel],
    );

    const row = result.rows[0];
    if (!row || !row.allowed) {
      throw new HttpException(
        {
          ok: false,
          code: row?.code || 'otp_verify_locked',
          message: row?.message || 'Demasiados intentos fallidos. Intenta más tarde.',
          retryAfterSeconds: row?.retry_after_seconds || null,
        },
        HttpStatus.TOO_MANY_REQUESTS,
      );
    }

    return { ok: true };
  }

  @Post('verify-attempt')
  async verifyAttempt(@Body() body: VerifyAttemptBody, @Req() req: any) {
    const channel = body.channel;
    if (channel !== 'sms' && channel !== 'email') {
      throw new BadRequestException('channel must be sms or email');
    }

    const identifier =
      channel === 'sms'
        ? this.normalizePhone(body.phone || '').identifier
        : this.normalizeEmail(body.email || '').identifier;

    const ipAddress = this.extractIp(req);

    await this.db.query(
      `select public.otp_guard_record_verify_attempt($1, $2, $3, $4)`,
      [identifier, channel, body.success, ipAddress],
    );

    return { ok: true };
  }

  @Post('email/confirm-request')
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'auth.otp.email-confirm', limit: 3, windowMs: 60_000, scope: 'user' })
  async requestEmailConfirmation(@Body() body: EmailConfirmBody, @Req() req: any) {
    const authz = (req?.headers?.authorization || '').toString();
    if (!authz.startsWith('Bearer ')) {
      throw new UnauthorizedException('Missing bearer token');
    }

    const claimsSub = this.rc.requireUuidUserId();

    const normalized = this.normalizeEmail(body.email || '');
    const email = normalized.email;

    const userCheck = await this.db.query<{
      email: string | null;
      email_confirmed_at: string | null;
    }>(
      `select email, email_confirmed_at
       from auth.users
       where id = $1
       limit 1`,
      [claimsSub],
    );

    const current = userCheck.rows[0];
    const currentEmail = (current?.email || '').trim().toLowerCase();
    const alreadyVerified = !!current?.email_confirmed_at;
    if (currentEmail === email && alreadyVerified) {
      return {
        ok: true,
        message: 'Email ya verificado.',
        status: 'already_verified',
      };
    }

    const bearer = authz.slice(7).trim();
    await this.updateSupabaseUserWithBearer(bearer, { email });

    return {
      ok: true,
      message: 'Correo de confirmación enviado.',
      status: 'confirmation_requested',
    };
  }
}
