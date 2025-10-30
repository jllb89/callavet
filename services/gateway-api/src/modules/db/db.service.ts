import { Injectable } from '@nestjs/common';
import { Pool } from 'pg';
import dns from 'node:dns';
import { lookup as dnsLookup } from 'node:dns/promises';
import fs from 'node:fs';
import { RequestContext } from '../auth/request-context.service';

@Injectable()
export class DbService {
  private pool?: Pool;
  private initPromise?: Promise<void>;
  constructor(private readonly rc: RequestContext){
    const url = process.env.DATABASE_URL;
    if (url) {
      const needsSsl = /[?&]sslmode=require/.test(url) || /supabase\.co/.test(url);
      let ssl: any = undefined;
      if (needsSsl) {
        const caPath = process.env.DATABASE_SSL_CA_PATH;
        const rejectUnauthorizedEnv = process.env.DATABASE_SSL_REJECT_UNAUTHORIZED;
        if (caPath && fs.existsSync(caPath)) {
          ssl = { ca: fs.readFileSync(caPath, 'utf8'), rejectUnauthorized: true };
        } else if (rejectUnauthorizedEnv === '0') {
          // Dev-only opt-out
          ssl = { rejectUnauthorized: false };
        } else {
          // Default: require TLS but allow platform CA bundle to validate
          ssl = { rejectUnauthorized: true };
        }
      }
      // Defer creating the Pool until first use so we can pre-resolve IPv4 address asynchronously
      const u = new URL(url);
      this.initPromise = undefined;
      const createPool = async () => {
        // Prefer IPv4; resolve the hostname ourselves and pass IPv4 literal to pg
        let host = u.hostname;
        try {
          const res = await dnsLookup(u.hostname, { family: 4, all: false });
          host = typeof res === 'string' ? res : res.address;
        } catch {
          // Fallback: try forcing ipv4-first at runtime
          try { (dns as any).setDefaultResultOrder?.('ipv4first'); } catch {}
        }
        const cfg: any = {
          host,
          port: u.port ? Number(u.port) : 5432,
          database: decodeURIComponent(u.pathname.replace(/^\//, '')),
          user: decodeURIComponent(u.username),
          password: decodeURIComponent(u.password),
          ssl,
        };
        this.pool = new Pool(cfg);
      };
      this.initPromise = createPool();
    }
  }
  get isStub(){ return !this.pool; }
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
