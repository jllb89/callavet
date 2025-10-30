import { Injectable } from '@nestjs/common';
import { AsyncLocalStorage } from 'node:async_hooks';

export interface JwtClaims {
  sub?: string;
  role?: string;
  email?: string;
  [k: string]: any;
}

@Injectable()
export class RequestContext {
  private als = new AsyncLocalStorage<JwtClaims | undefined>();

  runWithClaims<T>(claims: JwtClaims | undefined, fn: () => Promise<T> | T): Promise<T> | T {
    return this.als.run(claims, fn as any) as any;
  }

  get claims(): JwtClaims | undefined {
    return this.als.getStore();
  }
}
