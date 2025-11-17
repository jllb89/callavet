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
    if (authz?.startsWith('Bearer ') && secret) {
      const token = authz.slice(7);
      try {
        claims = jwt.verify(token, secret) as any;
      } catch {
        // optional in dev: ignore invalid tokens
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
