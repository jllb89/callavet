import { Injectable, UnauthorizedException } from '@nestjs/common';
import { AsyncLocalStorage } from 'node:async_hooks';

export interface JwtClaims {
  sub?: string;
  role?: string;
  email?: string;
  [k: string]: any;
}

export interface RequestState {
  requestId: string;
  claims?: JwtClaims;
}

@Injectable()
export class RequestContext {
  private als = new AsyncLocalStorage<RequestState | undefined>();
  private readonly uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  runWithState<T>(state: RequestState, fn: () => Promise<T> | T): Promise<T> | T {
    return this.als.run(state, fn as any) as any;
  }

  runWithClaims<T>(claims: JwtClaims | undefined, fn: () => Promise<T> | T): Promise<T> | T {
    return this.runWithState({ requestId: 'unknown', claims }, fn);
  }

  get claims(): JwtClaims | undefined {
    return this.als.getStore()?.claims;
  }

  get requestId(): string | undefined {
    return this.als.getStore()?.requestId;
  }

  get userId(): string | undefined {
    return this.claims?.sub;
  }

  get isAdmin(): boolean {
    const claims = this.claims;
    return !!claims && (!!claims.admin || claims.role === 'admin');
  }

  requireUserId(): string {
    const userId = this.userId;
    if (!userId) {
      throw new UnauthorizedException('missing_authenticated_user');
    }
    return userId;
  }

  requireUuidUserId(): string {
    const userId = this.requireUserId();
    if (!this.uuidRegex.test(userId)) {
      throw new UnauthorizedException('authenticated_user_id_must_be_uuid');
    }
    return userId;
  }
}
