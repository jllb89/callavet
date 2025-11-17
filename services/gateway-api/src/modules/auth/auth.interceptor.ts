import { CallHandler, ExecutionContext, Injectable, NestInterceptor } from '@nestjs/common';
import { Observable } from 'rxjs';
import { RequestContext, JwtClaims } from './request-context.service';
import { DbService } from '../db/db.service';

@Injectable()
export class AuthClaimsInterceptor implements NestInterceptor {
  constructor(private readonly rc: RequestContext, private readonly db: DbService) {}

  intercept(context: ExecutionContext, next: CallHandler): Observable<any> {
    const req = context.switchToHttp().getRequest<any>();
    const claims: JwtClaims | undefined = req?.authClaims;
    // Lightweight session provisioning / heartbeat update
    if (claims?.sub) {
      const ua = (req.headers['user-agent'] || '').toString().slice(0, 512);
      const ipHeader = (req.headers['x-forwarded-for'] || '').toString().split(',')[0].trim();
      const ip = ipHeader || (req.socket?.remoteAddress || '').replace('::ffff:', '').slice(0, 128);
      // Avoid unbounded growth: update existing recent session or create new if none within window
      (async () => {
        try {
          const { rows } = await this.db.query<{ id: string }>(
            `select id from auth_sessions
             where user_id = $1
               and (user_agent is not distinct from $2)
               and (ip is not distinct from $3)
               and revoked_at is null
               and last_used_at > now() - interval '15 minutes'
             order by last_used_at desc limit 1`,
            [claims.sub, ua || null, ip || null]
          );
          if (rows[0]) {
            await this.db.query(`update auth_sessions set last_used_at = now() where id = $1`, [rows[0].id]);
          } else {
            await this.db.query(
              `insert into auth_sessions(user_id, user_agent, ip, created_at, last_used_at)
               values ($1, $2, $3, now(), now())`,
              [claims.sub, ua || null, ip || null]
            );
          }
        } catch (e: any) {
          // Silently ignore when table missing or RLS denies access
          if (!/auth_sessions/.test(e?.message || '')) {
            // eslint-disable-next-line no-console
            console.warn('[auth-sessions] provisioning skipped:', e?.message || e);
          }
        }
      })();
    }
    let stream!: Observable<any>;
    this.rc.runWithClaims(claims, () => { stream = next.handle(); });
    return stream;
  }
}
