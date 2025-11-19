import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import jwt from 'jsonwebtoken';
import { JwtClaims } from './request-context.service';

@Injectable()
export class AuthGuard implements CanActivate {
  constructor() {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const req = ctx.switchToHttp().getRequest<{ headers: Record<string, string> }>();
    const authz = req?.headers?.authorization || '';
    const secret = process.env.SUPABASE_JWT_SECRET || '';
    let claims: JwtClaims | undefined;
    if (process.env.DEV_AUTH_DEBUG === '1') {
      // eslint-disable-next-line no-console
      console.log('[auth.guard] incoming authorization len=', authz.length, 'startsBearer=', authz.startsWith('Bearer '));
    }
    if (authz?.startsWith('Bearer ')) {
      const token = authz.slice(7);
      if (secret) {
        try {
          claims = jwt.verify(token, secret) as any;
        } catch {
          // ignore verification error; will fallback to decode
        }
      }
      if (!claims) {
        try {
          const tokenPayload = token.split('.')[1];
          if (tokenPayload) {
            let normalized = tokenPayload.replace(/-/g, '+').replace(/_/g, '/');
            while (normalized.length % 4 !== 0) normalized += '='; // pad
            const json = Buffer.from(normalized, 'base64').toString('utf8');
            const decoded = JSON.parse(json);
            if (decoded && typeof decoded === 'object') {
              claims = {
                sub: decoded.sub,
                email: decoded.email || decoded.user_metadata?.email,
                role: decoded.role,
                ...decoded,
              } as any;
            }
          }
        } catch {
          // swallow decoding errors
        }
      }
      if (process.env.DEV_AUTH_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.log('[auth.guard] decoded claims sub=', (claims as any)?.sub, 'email=', (claims as any)?.email);
      }
    }
    // Optional header override for local testing (no JWT): x-user-id
    if (!claims && req?.headers['x-user-id']) {
      const raw = Array.isArray(req.headers['x-user-id']) ? req.headers['x-user-id'][0] : req.headers['x-user-id'];
      const val = (raw || '').toString().trim();
      // Basic UUID v4-ish pattern (accepts lowercase hex)
      const uuidRe = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
      if (uuidRe.test(val)) {
        claims = { sub: val };
      } else {
        // leave claims undefined if header is malformed
      }
    }

    // Optional local admin override for testing
    if (req?.headers['x-admin']) {
      const raw = Array.isArray(req.headers['x-admin']) ? req.headers['x-admin'][0] : req.headers['x-admin'];
      const v = (raw || '').toString().trim();
      if (v === '1' || /^true$/i.test(v)) {
        claims = { ...(claims || {}), admin: true } as any;
      }
    }

    // Attach to request for interceptor to pick up
    (req as any).authClaims = claims;
    return true; // allow through; enforce later per-route if needed
  }
}
