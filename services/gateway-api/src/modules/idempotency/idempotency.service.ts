import { Injectable } from '@nestjs/common';

type Stored = {
  status: number;
  body: any;
  headers?: Record<string, string>;
  at: number;
};

@Injectable()
export class IdempotencyService {
  private store = new Map<string, Stored>();
  private ttlMs = 1000 * 60 * 60 * 24; // 24h

  get(key: string): Stored | undefined {
    const v = this.store.get(key);
    if (!v) return undefined;
    if (Date.now() - v.at > this.ttlMs) {
      this.store.delete(key);
      return undefined;
    }
    return v;
  }

  set(key: string, status: number, body: any, headers?: Record<string, string>) {
    this.store.set(key, { status, body, headers, at: Date.now() });
  }

  sweep() {
    const now = Date.now();
    for (const [k, v] of this.store.entries()) {
      if (now - v.at > this.ttlMs) this.store.delete(k);
    }
  }
}
