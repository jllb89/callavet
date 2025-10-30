import type { paths } from './generated';

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export type RequestOptions = {
  pathParams?: Record<string, string | number>;
  query?: Record<string, string | number | boolean | undefined>;
  headers?: Record<string, string>;
  body?: any;
  idempotencyKey?: string;
  bearerToken?: string;
  userIdDev?: string; // x-user-id for local/dev
};

function buildUrl(baseUrl: string, rawPath: string, pathParams?: Record<string, string | number>, query?: Record<string, string | number | boolean | undefined>) {
  let path = rawPath;
  if (pathParams) {
    for (const [k, v] of Object.entries(pathParams)) {
      path = path.replace(`{${k}}`, encodeURIComponent(String(v)));
      path = path.replace(`:${k}`, encodeURIComponent(String(v))); // support colon style if provided
    }
  }
  const url = new URL(path.startsWith('/') ? path : `/${path}`, baseUrl);
  if (query) {
    for (const [k, v] of Object.entries(query)) {
      if (v === undefined || v === null || v === '') continue;
      url.searchParams.set(k, String(v));
    }
  }
  return url.toString();
}

export class ApiClient {
  constructor(private baseUrl: string, private defaultHeaders: Record<string, string> = {}) {}

  setBaseUrl(url: string) { this.baseUrl = url; }

  async request<T = unknown>(method: HttpMethod, path: keyof paths | string, opts: RequestOptions = {}): Promise<{ status: number; data: T; ok: boolean; headers: Headers }>{
    const url = buildUrl(this.baseUrl, String(path), opts.pathParams, opts.query);
    const headers: Record<string, string> = { 'content-type': 'application/json', ...this.defaultHeaders, ...(opts.headers ?? {}) };
    if (opts.idempotencyKey) headers['Idempotency-Key'] = String(opts.idempotencyKey);
    if (opts.bearerToken) headers['Authorization'] = `Bearer ${opts.bearerToken}`;
    if (opts.userIdDev) headers['x-user-id'] = String(opts.userIdDev);

    const res = await fetch(url, { method, headers, body: opts.body != null ? JSON.stringify(opts.body) : undefined } as RequestInit);
    const text = await res.text();
    let data: any = undefined;
    try { data = text ? JSON.parse(text) : undefined; } catch { data = text as any; }
    return { status: res.status, data: data as T, ok: res.ok, headers: res.headers };
  }

  get<T = unknown>(path: keyof paths | string, opts?: RequestOptions) { return this.request<T>('GET', path, opts); }
  post<T = unknown>(path: keyof paths | string, opts?: RequestOptions) { return this.request<T>('POST', path, opts); }
  put<T = unknown>(path: keyof paths | string, opts?: RequestOptions) { return this.request<T>('PUT', path, opts); }
  patch<T = unknown>(path: keyof paths | string, opts?: RequestOptions) { return this.request<T>('PATCH', path, opts); }
  delete<T = unknown>(path: keyof paths | string, opts?: RequestOptions) { return this.request<T>('DELETE', path, opts); }

  // Convenience helpers for vector endpoints
  async vectorSearch(body: {
    target: 'kb' | 'messages' | 'notes' | 'products' | 'services' | 'pets' | 'vets';
    query_embedding: number[];
    topK?: number;
    filter_ids?: string[];
  }, opts: Omit<RequestOptions, 'body'> = {}) {
    return this.post<{ results: Array<{ id: string; score: number; snippet?: string; metadata?: Record<string, unknown> }> }>(
      '/vector/search',
      { ...opts, body },
    );
  }

  async vectorUpsert(body: {
    target: 'kb' | 'messages' | 'notes' | 'products' | 'services' | 'pets' | 'vets';
    items: Array<{ id: string; embedding: number[]; payload?: Record<string, unknown> }>;
  }, opts: Omit<RequestOptions, 'body'> = {}) {
    return this.post<{ ok: boolean }>(
      '/vector/upsert',
      { ...opts, body },
    );
  }
}
