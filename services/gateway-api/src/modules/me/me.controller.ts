import { Body, Controller, Get, Patch, Post, Put, Param, Delete, Req } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { PatchMeDto } from './dto/patch-me.dto';
// NOTE: Avoid static imports for optional deps (stripe, supabase-js) to prevent type errors when packages are not installed in certain envs.

interface UserRow {
  id: string;
  email: string;
  full_name?: string;
  role?: string;
  is_verified?: boolean;
  created_at?: string;
}

interface BillingProfileRow {
  user_id: string;
  stripe_customer_id?: string | null;
  default_payment_method?: string | null;
  billing_address?: any;
  tax_id?: string | null;
  preferred_language?: string | null;
  timezone?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
}

interface AuthSessionRow {
  id: string;
  user_id: string;
  created_at: string;
  last_used_at: string;
  revoked_at?: string | null;
  user_agent?: string | null;
  ip?: string | null;
}

@Controller('me')
export class MeController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

  private ensureAuthSub(): string {
    const sub = this.rc.claims?.sub;
    if (!sub) throw new (require('@nestjs/common').UnauthorizedException)('missing sub');
    return sub;
  }

  @Get()
  async getMe() {
    const sub = this.ensureAuthSub();
    const [u, bp] = await Promise.all([this.fetchUserRow(sub), this.fetchBillingProfile(sub)]);
    if (!u) {
      // Auto-provision minimal user record. Assumes RLS policy permitting insert where auth.uid() = id.
      const email = this.rc.claims?.email || `${sub}@placeholder.local`;
      try {
        await this.db.query(
          `insert into users(id, email, created_at)
           values ($1,$2, now())
           on conflict (id) do nothing`,
          [sub, email]
        );
      } catch (e: any) {
        // Provision failed (likely RLS). Surface reason for debugging.
        return { notFound: true, provisionAttempted: true, provisionError: e?.message || String(e) };
      }
      const [u2, bp2] = await Promise.all([this.fetchUserRow(sub), this.fetchBillingProfile(sub)]);
      if (!u2) return { notFound: true, provisionAttempted: true };
      return { provisioned: true, ...this.shapeUser(u2, bp2 || undefined) };
    }
    return this.shapeUser(u, bp || undefined);
  }

  @Patch()
  async patchMe(@Body() body: PatchMeDto) {
    const sub = this.ensureAuthSub();
    const existingColumns = await this.listUserColumns();
    // Update name in users if present
    if (body.name !== undefined && existingColumns.has('full_name')) {
      try {
        await this.db.query(`update users set full_name = $1, updated_at = now() where id = $2`, [body.name, sub]);
      } catch (e: any) {
        return { updated: false, reason: 'update_name_failed', error: e?.message || String(e) };
      }
    }
    // Upsert timezone into billing_profiles if provided
    if (body.timezone !== undefined) {
      try {
        await this.db.query(
          `insert into billing_profiles(user_id, timezone)
           values ($1, $2)
           on conflict (user_id) do update set timezone = excluded.timezone, updated_at = now()`,
          [sub, body.timezone]
        );
      } catch (e: any) {
        return { updated: false, reason: 'update_timezone_failed', error: e?.message || String(e) };
      }
    }
    const [u, bp] = await Promise.all([this.fetchUserRow(sub), this.fetchBillingProfile(sub)]);
    return { updated: true, user: this.shapeUser(u!, bp || undefined) };
  }

  private shapeUser(u: UserRow, bp?: BillingProfileRow) {
    return {
      id: u.id,
      email: u.email,
      name: (u as any).full_name || null,
      role: (u as any).role || null,
      timezone: bp?.timezone || null,
      billing: bp ? {
        tax_id: bp.tax_id || null,
        address: bp.billing_address || null,
        stripe_customer_id: bp.stripe_customer_id || null,
        default_payment_method: bp.default_payment_method || null
      } : null,
      isVerified: (u as any).is_verified ?? false,
      createdAt: (u as any).created_at || null,
    };
  }

  private async listUserColumns(): Promise<Set<string>> {
    try {
      const { rows } = await this.db.query<{ column_name: string }>(`select column_name from information_schema.columns where table_name='users' and table_schema='public'`);
      return new Set(rows.map(r => r.column_name));
    } catch {
      return new Set();
    }
  }

  private async fetchUserRow(sub: string): Promise<UserRow | undefined> {
    // Try widest selection; progressively narrow if columns missing
    const attempts = [
      `select id, email, full_name, role, created_at from users where id = $1 limit 1`,
      `select id, email, created_at from users where id = $1 limit 1`
    ];
    for (const sql of attempts) {
      try {
        const { rows } = await this.db.query<UserRow>(sql, [sub]);
        if (rows[0]) return rows[0];
        return undefined;
      } catch (e: any) {
        // Continue to next attempt if column missing error
        if (!/column .* does not exist/i.test(e?.message || '')) {
          // Non-column error: surface immediately
          throw e;
        }
      }
    }
    return undefined;
  }

  private async fetchBillingProfile(userId: string): Promise<BillingProfileRow | undefined> {
    try {
      const { rows } = await this.db.query<BillingProfileRow>(
        `select user_id, stripe_customer_id, default_payment_method, billing_address, tax_id, preferred_language, timezone, created_at, updated_at
         from billing_profiles where user_id = $1 limit 1`,
        [userId]
      );
      return rows[0];
    } catch (e: any) {
      if (/billing_profiles/.test(e?.message || '')) return undefined;
      throw e;
    }
  }

  // ---------------- Sessions ----------------
  @Get('security/sessions')
  async listSessions(){
    const sub = this.ensureAuthSub();
    // If table missing, return stub
    try {
      const { rows } = await this.db.query<AuthSessionRow>(`select id, created_at, last_used_at, revoked_at, user_agent, ip from auth_sessions where user_id = $1 order by created_at desc limit 100`, [sub]);
      return {
        userId: sub,
        sessions: rows.map(r => ({
          id: r.id,
            createdAt: r.created_at,
            lastUsedAt: r.last_used_at,
            revokedAt: r.revoked_at || null,
            userAgent: r.user_agent || null,
            ip: r.ip || null,
            active: !r.revoked_at
        }))
      };
    } catch (e: any) {
      if (/auth_sessions/.test(e?.message || '')) {
        return { userId: sub, sessions: [], stub: true };
      }
      throw e;
    }
  }

  @Post('security/logout-all')
  async logoutAll(){
    const sub = this.ensureAuthSub();
    try {
      // Soft revoke: set revoked_at on all active rows
      const { rows } = await this.db.query<{ count: string }>(`with upd as (
        update auth_sessions set revoked_at = now() where user_id = $1 and revoked_at is null returning 1
      ) select count(*)::text as count from upd`, [sub]);
      const count = rows[0] ? Number(rows[0].count) : 0;
      return { userId: sub, revoked: count };
    } catch (e: any) {
      if (/auth_sessions/.test(e?.message || '')) {
        return { userId: sub, revoked: 0, stub: true };
      }
      throw e;
    }
  }

  @Post('security/logout-all-supabase')
  async logoutAllSupabase(@Req() req: any){
    const sub = this.rc.claims?.sub; // optional; not strictly required when using bearer for admin sign-out
    const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY || '';
    let supabaseUrl = process.env.SUPABASE_URL || '';
    if (!supabaseUrl) {
      // Derive from DATABASE_URL like: db.<ref>.supabase.co -> https://<ref>.supabase.co
      try {
        const du = process.env.DATABASE_URL ? new URL(process.env.DATABASE_URL) : null;
        const host = du?.hostname || '';
        const m = host.match(/^db\.(.*?)\.supabase\.co$/);
        if (m && m[1]) supabaseUrl = `https://${m[1]}.supabase.co`;
      } catch {}
    }
    if (!serviceKey || !supabaseUrl) {
      return { ok: false, reason: 'missing_supabase_admin_env', supabaseUrl: !!supabaseUrl, serviceKey: !!serviceKey };
    }
    try {
      // Load supabase-js (CJS main supported in v2) at runtime
      const { createClient } = require('@supabase/supabase-js');
      const client = createClient(supabaseUrl, serviceKey);
      // Prefer bearer token if provided to perform global sign-out for that user
      const authz = (req?.headers?.authorization || '').toString();
      if (authz?.startsWith('Bearer ')) {
        const jwt = authz.slice(7);
        const { error } = await client.auth.admin.signOut(jwt, 'global');
        if (error) return { ok: false, error: error.message };
        return { ok: true, mode: 'admin.signOut.global' };
      }
      // If no bearer, we cannot globally sign out via Admin API without a JWT
      return { ok: false, reason: 'missing_bearer', hint: 'Pass Authorization: Bearer <sb-access-token> to revoke all sessions globally.' };
    } catch (e: any) {
      return { ok: false, error: e?.message || String(e) };
    }
  }

  // ---------------- Billing profile ----------------
  @Get('billing-profile')
  async getBillingProfile(){
    const sub = this.ensureAuthSub();
    const bp = await this.fetchBillingProfile(sub);
    if (!bp) return { notFound: true };
    return {
      userId: sub,
      stripe_customer_id: bp.stripe_customer_id || null,
      default_payment_method: bp.default_payment_method || null,
      tax_id: bp.tax_id || null,
      timezone: bp.timezone || null,
      preferred_language: bp.preferred_language || 'es',
      billing_address: bp.billing_address || null,
      created_at: bp.created_at || null,
      updated_at: bp.updated_at || null,
    };
  }

  @Put('billing-profile')
  async putBillingProfile(@Body() body: { tax_id?: string; timezone?: string; preferred_language?: string; billing_address?: any }){
    const sub = this.ensureAuthSub();
    // MX RFC basic shape check if provided (lenient)
    if (body.tax_id && !/^[A-ZÑ&]{3,4}[0-9]{6}[A-Z0-9]{3}$/.test(body.tax_id.toUpperCase())){
      const { BadRequestException } = require('@nestjs/common');
      throw new BadRequestException('tax_id must be RFC-like (e.g. ABCD001122XXX)');
    }
    // Upsert merge: keep existing fields unless overwritten
    const existing = await this.fetchBillingProfile(sub);
    const next = {
      tax_id: body.tax_id ?? existing?.tax_id ?? null,
      timezone: body.timezone ?? existing?.timezone ?? null,
      preferred_language: body.preferred_language ?? existing?.preferred_language ?? 'es',
      billing_address: body.billing_address ?? existing?.billing_address ?? null,
    };
    await this.db.query(
      `insert into billing_profiles(user_id, tax_id, timezone, preferred_language, billing_address)
       values ($1,$2,$3,$4,$5)
       on conflict (user_id) do update set
         tax_id = excluded.tax_id,
         timezone = excluded.timezone,
         preferred_language = excluded.preferred_language,
         billing_address = excluded.billing_address,
         updated_at = now()`,
      [sub, next.tax_id, next.timezone, next.preferred_language, next.billing_address]
    );
    const bp = await this.fetchBillingProfile(sub);
    return {
      updated: true,
      profile: {
        userId: sub,
        tax_id: bp?.tax_id || null,
        timezone: bp?.timezone || null,
        preferred_language: bp?.preferred_language || 'es',
        billing_address: bp?.billing_address || null,
      }
    };
  }

  // ---------------- Payment methods (Stripe) ----------------
  private getStripe(): any | null {
    const key = process.env.STRIPE_SECRET_KEY || '';
    if (!key) return null;
    const Stripe = require('stripe');
    return new Stripe(key, { apiVersion: '2024-06-20' } as any);
  }

  private async ensureStripeCustomerFor(userId: string): Promise<string | null> {
    const bp = await this.fetchBillingProfile(userId);
    if (bp?.stripe_customer_id) return bp.stripe_customer_id;
    const stripe = this.getStripe();
    if (!stripe) return null;
    // Fetch minimal user info for metadata/email
    const u = await this.fetchUserRow(userId);
    const customer = await stripe.customers.create({
      email: (u as any)?.email,
      metadata: { user_id: userId }
    });
    await this.db.query(
      `insert into billing_profiles(user_id, stripe_customer_id)
       values ($1,$2)
       on conflict (user_id) do update set stripe_customer_id = excluded.stripe_customer_id, updated_at = now()`,
      [userId, customer.id]
    );
    return customer.id;
  }

  @Post('billing/payment-method/attach')
  async attachPaymentMethod(@Body() body: { payment_method_id?: string; return_url?: string }){
    const sub = this.ensureAuthSub();
    const stripe = this.getStripe();
    if (!stripe) return { ok: false, reason: 'stripe_missing_secret' };
    const customerId = await this.ensureStripeCustomerFor(sub);
    if (!customerId) return { ok: false, reason: 'customer_create_failed' };
    if (!body.payment_method_id) {
      const si = await stripe.setupIntents.create({ customer: customerId, usage: 'off_session' });
      return { ok: true, setup_intent_client_secret: si.client_secret };
    }
    // Attach provided PM and set as default
    const pm = await stripe.paymentMethods.attach(body.payment_method_id, { customer: customerId });
    await stripe.customers.update(customerId, { invoice_settings: { default_payment_method: pm.id } });
    await this.db.query(
      `update billing_profiles set default_payment_method = $1, updated_at = now() where user_id = $2`,
      [pm.id, sub]
    );
    return { ok: true, payment_method: { id: pm.id, type: pm.type } };
  }

  @Delete('billing/payment-method/:pmId')
  async detachPaymentMethod(@Param('pmId') pmId: string){
    const sub = this.ensureAuthSub();
    const stripe = this.getStripe();
    if (!stripe) return { ok: false, reason: 'stripe_missing_secret' };
    const bp = await this.fetchBillingProfile(sub);
    if (!bp?.stripe_customer_id) return { ok: false, reason: 'no_customer' };
    // Optional ownership check: fetch PM and ensure it's attached to this customer
    const pm = await stripe.paymentMethods.retrieve(pmId);
    const attachedTo = (pm as any).customer;
    if (attachedTo && attachedTo !== bp.stripe_customer_id) return { ok: false, reason: 'not_owner' };
    await stripe.paymentMethods.detach(pmId);
    if (bp.default_payment_method === pmId) {
      await this.db.query(
        `update billing_profiles set default_payment_method = null, updated_at = now() where user_id = $1`,
        [sub]
      );
      await stripe.customers.update(bp.stripe_customer_id, { invoice_settings: { default_payment_method: null } });
    }
    return { ok: true, detached: pmId };
  }
}
