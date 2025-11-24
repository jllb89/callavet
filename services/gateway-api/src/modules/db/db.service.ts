import { Injectable } from '@nestjs/common';
import { Pool } from 'pg';
import dns from 'node:dns';
import fs from 'node:fs';
import { RequestContext } from '../auth/request-context.service';

@Injectable()
export class DbService {
  private pool?: Pool;
  private initPromise?: Promise<void>;
  private lastError?: string;
  constructor(private readonly rc: RequestContext){
    const url = process.env.DATABASE_URL;
    if (!url) {
      if (process.env.DEV_DB_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.error('[db:init] DATABASE_URL missing in process.env (stub mode).');
      }
    }
    if (url) {
      if (process.env.DEV_DB_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.log('[db:init] raw url=', url);
      }
      const needsSsl = /[?&]sslmode=require/.test(url) || /supabase\.co/.test(url);
      let ssl: any = undefined;
      if (needsSsl) {
        const caPath = process.env.DATABASE_SSL_CA_PATH;
        const rejectUnauthorizedEnv = process.env.DATABASE_SSL_REJECT_UNAUTHORIZED;
        const nodeEnv = process.env.NODE_ENV || 'development';
        // Honor explicit CA bundle first
        if (caPath && fs.existsSync(caPath)) {
          ssl = { ca: fs.readFileSync(caPath, 'utf8'), rejectUnauthorized: true };
        } else {
          // Determine whether to skip cert verification in local/dev contexts
          const pgSslMode = (process.env.PGSSLMODE || '').toLowerCase();
          const noVerifyModes = new Set(['allow', 'prefer', 'no-verify']);
          const isDev = nodeEnv !== 'production';
          const disableVerify = rejectUnauthorizedEnv === '0' || noVerifyModes.has(pgSslMode) || isDev;
          ssl = { rejectUnauthorized: !disableVerify };
        }
      }
      // Defer creating the Pool until first use so we can pre-resolve IPv4 address asynchronously
      const u = new URL(url);
      this.initPromise = undefined;
      const createPool = async () => {
        // Enhanced resolution & diagnostics to defeat ENETUNREACH (IPv6) in container
        const originalHost = u.hostname;
        const overrideHost = process.env.DATABASE_FORCE_HOST?.trim();
        let host = overrideHost || originalHost;
        const forceIpv4 = process.env.DB_FORCE_IPV4 !== '0';
        let resolvedV4: string[] = [];
        let resolvedV6: string[] = [];
        if (process.env.DEV_DB_DEBUG === '1') {
          // eslint-disable-next-line no-console
          console.log('[db:init] starting resolution originalHost=', originalHost, ' overrideHost=', overrideHost || '(none)');
        }
        try {
          resolvedV4 = await dns.promises.resolve4(originalHost);
        } catch (e: any) {
          if (process.env.DEV_DB_DEBUG === '1') {
            // eslint-disable-next-line no-console
            console.warn('[db:init] resolve4 failed', e?.message);
          }
        }
        try {
          resolvedV6 = await dns.promises.resolve6(originalHost);
        } catch (e: any) {
          if (process.env.DEV_DB_DEBUG === '1') {
            // eslint-disable-next-line no-console
            console.warn('[db:init] resolve6 failed', e?.message);
          }
        }
        if (forceIpv4 && resolvedV4.length) {
          host = resolvedV4[0];
        }
        if (process.env.DEV_DB_DEBUG === '1') {
          // eslint-disable-next-line no-console
          console.log('[db:init] resolvedV4=', resolvedV4, ' resolvedV6(count)=', resolvedV6.length, ' chosen host=', host, ' forceIpv4=', forceIpv4);
        }
        const cfg: any = {
          host,
          port: u.port ? Number(u.port) : 5432,
          database: decodeURIComponent(u.pathname.replace(/^\//, '')),
          user: decodeURIComponent(u.username),
          password: decodeURIComponent(u.password),
          ssl,
        };
        try {
          this.pool = new Pool(cfg);
        } catch (e: any) {
          this.lastError = e?.message || String(e);
          // eslint-disable-next-line no-console
          console.error('[db] pool constructor failed:', this.lastError);
          if (process.env.DEV_REQUIRE_DB === '1') throw e;
          return; // leave in stub mode
        }
        // Probe connectivity early to surface auth/ssl errors now rather than first query later
        try {
          await (this.pool as any).query('select 1');
          // eslint-disable-next-line no-console
          console.log('[db] pool init success host=' + host + ' db=' + cfg.database + ' ssl=' + (ssl ? JSON.stringify(ssl) : 'none'));
        } catch (e: any) {
          this.lastError = e?.message || String(e);
          // eslint-disable-next-line no-console
          console.error('[db] initial connectivity test failed:', this.lastError);
          // Attempt fallback: if we resolved to an IP and failed with ENETUNREACH, retry with original hostname once
          if (forceIpv4 && host !== originalHost && /ENETUNREACH/.test(this.lastError || '')) {
            try {
              // eslint-disable-next-line no-console
              console.warn('[db] ENETUNREACH on IPv4 address? Retrying with original hostname:', originalHost);
              const cfg2 = { ...cfg, host: originalHost };
              const retryPool = new Pool(cfg2);
              await (retryPool as any).query('select 1');
              this.pool?.end().catch(() => {});
              this.pool = retryPool;
              // eslint-disable-next-line no-console
              console.log('[db] fallback to hostname succeeded host=' + originalHost);
              this.lastError = undefined;
            } catch (e2: any) {
              // eslint-disable-next-line no-console
              console.error('[db] fallback hostname attempt failed:', e2?.message || String(e2));
            }
          }
          if (process.env.DEV_REQUIRE_DB === '1' && this.lastError) throw e;
        }
      };
      // Start initialization immediately and awaitable via ensureReady()
      this.initPromise = createPool().catch((e) => {
        // Surface pool init errors but keep stub fallback to avoid crashing entire app
        // eslint-disable-next-line no-console
        const msg = e?.message || String(e);
        console.error('[db] pool init failed:', msg);
        this.lastError = msg;
        this.pool = undefined;
      });
    }
  }
  get isStub(){ return !this.pool; }
  get status(){
    return {
      stub: this.isStub,
      lastError: this.lastError,
      hasEnvUrl: !!process.env.DATABASE_URL,
      devRequireDb: process.env.DEV_REQUIRE_DB === '1',
      devDbDebug: process.env.DEV_DB_DEBUG === '1'
    };
  }
  async ensureReady(){ if (this.initPromise) await this.initPromise; }
  async query<T = any>(text: string, params?: any[]): Promise<{ rows: T[] }>{
    if (!this.pool) {
      if (this.initPromise) await this.initPromise;
      // Stubbed response for local dev without DB
      if (!this.pool) return { rows: [] as T[] };
    }
    // Use broad typing to keep it simple; callers can cast
    return (this.pool.query as any)(text, params) as Promise<{ rows: T[] }>;
  }

  async runInTx<T>(fn: (q: <R = any>(sql: string, args?: any[]) => Promise<{ rows: R[] }>) => Promise<T>): Promise<T> {
    if (!this.pool) {
      if (this.initPromise) await this.initPromise;
      if (!this.pool) return fn(async () => ({ rows: [] })) as any;
    }
    const client = await this.pool.connect();
    try {
      await client.query('begin');
      const claims = this.rc.claims;
      if (claims) {
        await client.query(`select set_config('request.jwt.claims', $1, true)`, [JSON.stringify(claims)]);
        // Supabase helper functions like auth.uid() rely on individual claim keys (request.jwt.claim.sub)
        // Populate sub (and commonly email) explicitly so auth.uid() resolves correctly.
        if ((claims as any).sub) {
          await client.query(`select set_config('request.jwt.claim.sub', $1, true)`, [(claims as any).sub]);
        }
        if ((claims as any).email) {
          await client.query(`select set_config('request.jwt.claim.email', $1, true)`, [(claims as any).email]);
        }
      }
      const q = async <R = any>(sql: string, args?: any[]) => (client.query as any)(sql, args) as Promise<{ rows: R[] }>;
      const result = await fn(q);
      await client.query('commit');
      return result;
    } catch (e) {
      try { await client.query('rollback'); } catch {}
      throw e;
    } finally {
      client.release();
    }
  }
}
