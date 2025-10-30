import { Injectable } from '@nestjs/common';
import { Pool } from 'pg';
import dns from 'node:dns';
import fs from 'node:fs';
import { RequestContext } from '../auth/request-context.service';

@Injectable()
export class DbService {
  private pool?: Pool;
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
      // Force IPv4 to avoid ENETUNREACH when IPv6 routes are unavailable in some hosts
      const lookup: any = (hostname: string, options: any, callback: any) => {
        return dns.lookup(hostname, { family: 4, all: false }, callback);
      };
      // Parse URL to explicit fields to ensure our lookup is used
      const u = new URL(url);
      const cfg: any = {
        host: u.hostname,
        port: u.port ? Number(u.port) : 5432,
        database: decodeURIComponent(u.pathname.replace(/^\//, '')),
        user: decodeURIComponent(u.username),
        password: decodeURIComponent(u.password),
        ssl,
        lookup,
      };
      this.pool = new Pool(cfg);
    }
  }
  get isStub(){ return !this.pool; }
  async query<T = any>(text: string, params?: any[]): Promise<{ rows: T[] }>{
    if (!this.pool) {
      // Stubbed response for local dev without DB
      return { rows: [] as T[] };
    }
    // Use broad typing to keep it simple; callers can cast
    return (this.pool.query as any)(text, params) as Promise<{ rows: T[] }>;
  }

  async runInTx<T>(fn: (q: <R = any>(sql: string, args?: any[]) => Promise<{ rows: R[] }>) => Promise<T>): Promise<T> {
    if (!this.pool) {
      return fn(async () => ({ rows: [] })) as any;
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
