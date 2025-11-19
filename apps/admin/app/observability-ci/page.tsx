"use client";

import { useEffect, useMemo, useState, useRef } from "react";
import { createClient, SupabaseClient, Session, User, AuthChangeEvent } from "@supabase/supabase-js";
import YAML from "yaml";

type HttpMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "WS";
type EnvKey = "local" | "staging" | "production";

type Endpoint = {
  method: HttpMethod;
  path: string; // e.g. /pets/:petId
  label?: string;
  who?: string; // visibility
  status?: 'done' | 'todo';
  notes?: string;
  description?: string; // tooltip
  bodySample?: any;
  querySample?: Record<string, string>;
  pathParams?: string[]; // ["petId"]
  host?: "gateway" | "webhooks" | "chat" | "video" | "internal";
};

type EndpointGroup = {
  name: string;
  items: Endpoint[];
};

const DEFAULT_TEST_USER = "00000000-0000-0000-0000-000000000002";

// Minimal status map for implemented routes in gateway today
// Key format: `${METHOD} ${PATH_WITH_COLONS}`
const ROUTE_STATUS: Record<string, 'done'|'todo'> = {
  'GET /health': 'done',
  'GET /version': 'done',
  'GET /time': 'done',
  'POST /sessions/start': 'done',
  'POST /sessions/end': 'done',
  'GET /sessions': 'done',
  'GET /sessions/:sessionId': 'done',
  'PATCH /sessions/:sessionId': 'done',
  'GET /subscriptions/usage': 'done',
  'GET /subscriptions/usage/current': 'done',
  'GET /subscriptions/my': 'done',
  'GET /centers/near': 'done',
  'POST /vector/search': 'done',
  'POST /vector/upsert': 'done',
  'GET /vector/search': 'done',
  'POST /vector/search (kb)': 'done',
  'POST /vector/upsert (kb)': 'done',
  'GET /kb': 'done',
  'GET /kb/:id': 'done',
  'POST /kb': 'done',
  'PATCH /kb/:id/publish': 'done',
  'GET /search': 'done',
};

const ENV_URLS: Record<EnvKey, { gateway: string; webhooks: string; chat?: string; video?: string }> = {
  local: {
    gateway: "http://localhost:4000",
    webhooks: "http://localhost:4200",
    chat: "ws://localhost:4100",
    video: "http://localhost:4300",
  },
  staging: {
    gateway: "https://staging.api.callavet.mx",
    webhooks: "https://staging.webhooks.callavet.mx",
    chat: "wss://staging.chat.callavet.mx",
    video: "https://staging.video.callavet.mx",
  },
  production: {
    gateway: "https://api.callavet.mx",
    webhooks: "https://webhooks.callavet.mx",
    chat: "wss://chat.callavet.mx",
    video: "https://video.callavet.mx",
  },
};

const STATIC_GROUPS: EndpointGroup[] = [
  {
    name: "System / Meta",
    items: [
      { method: "GET", path: "/health", who: "Public" },
      { method: "GET", path: "/version", who: "Public" },
      { method: "GET", path: "/time", who: "Public" },
    ],
  },
  {
    name: "Auth & Profile",
    items: [
      { method: "GET", path: "/me", who: "User/Vet/Admin", description: "Fetch current authenticated user's profile (basic fields + role + timezone)." },
      { method: "PATCH", path: "/me", who: "User/Vet/Admin", description: "Update mutable profile fields: name, timezone (IANA)." },
      { method: "GET", path: "/me/security/sessions", who: "User/Vet/Admin", description: "List active auth sessions (tokens) for this user." },
      { method: "POST", path: "/me/security/logout-all", who: "User/Vet/Admin", bodySample: {}, description: "Revoke / delete all active sessions for this user." },
  { method: "POST", path: "/me/security/logout-all-supabase", who: "Admin", bodySample: {}, description: "Invalidate all Supabase refresh tokens for this user via Admin API (service key required)." },
      { method: "GET", path: "/me/billing-profile", who: "User/Vet/Admin", description: "Retrieve billing profile (tax_id, address) if configured." },
      { method: "PUT", path: "/me/billing-profile", who: "User/Vet/Admin", bodySample: { tax_id: "XAXX010101000", address: { line1: "Av. Siempre Viva 123", country: "MX" } }, description: "Upsert billing profile fields (validate MX RFC and address)." },
      { method: "POST", path: "/me/billing/payment-method/attach", who: "User/Vet", bodySample: { return_url: "http://localhost:3000" }, description: "Create/attach a payment method (Stripe SetupIntent)." },
      { method: "DELETE", path: "/me/billing/payment-method/:pmId", who: "User/Vet", pathParams: ["pmId"], bodySample: {}, description: "Detach a stored payment method from billing profile." },
    ],
  },
  {
    name: "Pets",
    items: [
      { method: "GET", path: "/pets", who: "User" },
      { method: "POST", path: "/pets", who: "User", bodySample: { name: "Firulais", species: "dog" } },
      { method: "GET", path: "/pets/:petId", who: "User", pathParams: ["petId"] },
      { method: "PATCH", path: "/pets/:petId", who: "User", pathParams: ["petId"], bodySample: { notes: "Allergic to chicken" } },
      { method: "DELETE", path: "/pets/:petId", who: "User", pathParams: ["petId"] },
      { method: "POST", path: "/pets/:petId/files/signed-url", who: "User", pathParams: ["petId"], bodySample: { filename: "photo.jpg" } },
      { method: "GET", path: "/pets/:petId/cases", who: "User", pathParams: ["petId"] },
      { method: "POST", path: "/pets/:petId/cases", who: "User", pathParams: ["petId"], bodySample: { labels: ["skin"], findings: "rash" } },
    ],
  },
  {
    name: "Vets & Specialties",
    items: [
      { method: "GET", path: "/vets", who: "Public", querySample: { language: "es" } },
      { method: "GET", path: "/vets/:vetId", who: "Public", pathParams: ["vetId"] },
      { method: "GET", path: "/specialties", who: "Public" },
      { method: "GET", path: "/me/vet", who: "Vet" },
      { method: "PUT", path: "/me/vet", who: "Vet", bodySample: { bio: "10y experience", languages: ["es", "en"] } },
      { method: "GET", path: "/me/vet/availability", who: "Vet" },
      { method: "PUT", path: "/me/vet/availability", who: "Vet", bodySample: { mon: ["09:00-12:00"] } },
      { method: "POST", path: "/me/vet/availability/overrides", who: "Vet", bodySample: { date: "2025-12-24", closed: true } },
      { method: "DELETE", path: "/me/vet/availability/overrides/:id", who: "Vet", pathParams: ["id"] },
    ],
  },
  {
    name: "Clinics / Centers",
    items: [
      { method: "GET", path: "/centers/near", who: "Public", querySample: { lat: "19.43", lng: "-99.13", radius: "10" } },
      { method: "GET", path: "/centers/:centerId", who: "Public", pathParams: ["centerId"] },
      { method: "POST", path: "/centers", who: "Admin", bodySample: { name: "Vet Center" } },
      { method: "PATCH", path: "/centers/:centerId", who: "Admin", pathParams: ["centerId"], bodySample: { phone: "+52..." } },
      { method: "POST", path: "/vets/:vetId/centers/:centerId", who: "Admin", pathParams: ["vetId", "centerId"] },
      { method: "DELETE", path: "/vets/:vetId/centers/:centerId", who: "Admin", pathParams: ["vetId", "centerId"] },
    ],
  },
  {
    name: "Subscriptions & Entitlements",
    items: [
      { method: "GET", path: "/plans", who: "Public" },
      { method: "GET", path: "/plans/:code", who: "Public", pathParams: ["code"] },
      { method: "GET", path: "/subscriptions/my", who: "User" },
      { method: "GET", path: "/subscriptions/usage/current", who: "User" },
      { method: "POST", path: "/subscriptions/checkout", who: "User", bodySample: { plan_code: "plus", seats: 1 } },
      { method: "POST", path: "/subscriptions/portal", who: "User" },
      { method: "POST", path: "/subscriptions/cancel", who: "User" },
      { method: "POST", path: "/subscriptions/resume", who: "User" },
      { method: "POST", path: "/subscriptions/change-plan", who: "User", bodySample: { code: "pro", seats: 2 } },
      { method: "POST", path: "/entitlements/reserve", who: "User", bodySample: { type: "chat", sessionId: "SESSION_UUID" } },
      { method: "POST", path: "/entitlements/commit", who: "User", bodySample: { consumptionId: "CONSUMPTION_UUID" } },
      { method: "POST", path: "/entitlements/release", who: "User", bodySample: { consumptionId: "CONSUMPTION_UUID" } },
    ],
  },
  {
    name: "Payments & Invoices",
    items: [
      { method: "GET", path: "/payments", who: "User" },
      { method: "GET", path: "/payments/:paymentId", who: "User", pathParams: ["paymentId"] },
      { method: "GET", path: "/invoices", who: "User" },
      { method: "GET", path: "/invoices/:invoiceId", who: "User", pathParams: ["invoiceId"] },
      { method: "POST", path: "/payments/one-off/checkout", who: "User", bodySample: { amount: 1999, currency: "mxn" } },
    ],
  },
  {
    name: "Sessions",
    items: [
      { method: "POST", path: "/sessions/start", who: "User", bodySample: { mode: "chat", pet_id: "PET_UUID", text: "Hola" } },
      { method: "POST", path: "/sessions/end", who: "User/Vet", bodySample: { sessionId: "SESSION_UUID" } },
      { method: "GET", path: "/sessions", who: "User/Vet" },
      { method: "GET", path: "/sessions/:sessionId", who: "User/Vet", pathParams: ["sessionId"] },
      { method: "PATCH", path: "/sessions/:sessionId", who: "Vet/Admin", pathParams: ["sessionId"], bodySample: { status: "no_show" } },
      { method: "GET", path: "/sessions/:sessionId/messages", who: "User/Vet", pathParams: ["sessionId"] },
      { method: "POST", path: "/sessions/:sessionId/messages", who: "User/Vet/AI", pathParams: ["sessionId"], bodySample: { role: "user", content: "Hi" } },
      { method: "GET", path: "/sessions/:sessionId/transcript", who: "User/Vet", pathParams: ["sessionId"] },
    ],
  },
  {
    name: "Video (LiveKit)",
    items: [
      { method: "POST", path: "/video/rooms", who: "Internal" },
      { method: "POST", path: "/video/rooms/:roomId/end", who: "Gateway/Admin", pathParams: ["roomId"] },
      { method: "GET", path: "/video/rooms/:roomId/recordings", who: "Admin", pathParams: ["roomId"] },
    ],
  },
  {
    name: "Notes, Care Plans & Cases",
    items: [
      { method: "GET", path: "/sessions/:sessionId/notes", who: "User/Vet", pathParams: ["sessionId"] },
      { method: "POST", path: "/sessions/:sessionId/notes", who: "Vet", pathParams: ["sessionId"], bodySample: { summary: "SOAP..." } },
      { method: "GET", path: "/pets/:petId/care-plans", who: "User/Vet", pathParams: ["petId"] },
      { method: "POST", path: "/pets/:petId/care-plans", who: "Vet", pathParams: ["petId"], bodySample: { title: "Plan A" } },
      { method: "GET", path: "/care-plans/:planId/items", who: "User/Vet", pathParams: ["planId"] },
      { method: "POST", path: "/care-plans/:planId/items", who: "Vet", pathParams: ["planId"], bodySample: { type: "consult" } },
      { method: "PATCH", path: "/care-plans/items/:itemId", who: "Vet/Admin", pathParams: ["itemId"], bodySample: { status: "done" } },
      { method: "GET", path: "/pets/:petId/image-cases", who: "User/Vet", pathParams: ["petId"] },
      { method: "POST", path: "/pets/:petId/image-cases", who: "User/Vet", pathParams: ["petId"], bodySample: { image_url: "https://..." } },
      { method: "GET", path: "/image-cases/:id", who: "User/Vet", pathParams: ["id"] },
    ],
  },
  {
    name: "Appointments",
    items: [
      { method: "GET", path: "/appointments", who: "User/Vet" },
      { method: "POST", path: "/appointments", who: "User", bodySample: { vet_id: "VET_UUID", pet_id: "PET_UUID", starts_at: "2025-10-29T12:00:00Z" } },
      { method: "PATCH", path: "/appointments/:id", who: "User/Vet/Admin", pathParams: ["id"], bodySample: { status: "canceled" } },
      { method: "GET", path: "/vets/:vetId/availability/slots", who: "Public/User", pathParams: ["vetId"], querySample: { from: "2025-10-29", to: "2025-11-05" } },
    ],
  },
  {
    name: "Knowledge Base & Search",
    items: [
      { method: "GET", path: "/kb", who: "Public", querySample: { species: "dog" }, description: "List published KB articles (or author drafts if authenticated) filtered by species/tags." },
      { method: "GET", path: "/kb/d920ad16-2f7c-4a6e-99f2-44f925834a72", who: "Public", description: "Fetch a single KB article by ID (published or own draft)." },
      { method: "POST", path: "/kb", who: "Admin/Vet", bodySample: { title: "Vomiting in Dogs", content: "Dogs may vomit for many reasons. Observe frequency, bile, blood, foreign bodies, and dehydration.", tags: ["gi","emesis"], species: ["dog"], language: "en" }, description: "Create a draft KB article; visible only to author/admin until published." },
      { method: "PATCH", path: "/kb/d920ad16-2f7c-4a6e-99f2-44f925834a72/publish", who: "Admin", bodySample: {}, notes: "Requires admin override", description: "Publish an existing draft KB article, setting status=published and timestamp." },
      { method: "GET", path: "/search", who: "Auth varies", querySample: { q: "rash", type: "kb" }, description: "Lexical search over KB articles using tsvector ranking and fallback." },
      { method: "GET", path: "/vector/search", who: "Auth varies", querySample: { target: "kb", embedding: "[0,0.1,0.2]", topK: "5", filter_ids: "[\"d920ad16-2f7c-4a6e-99f2-44f925834a72\"]" }, description: "Semantic vector search against KB embeddings using cosine distance." },
  // Vector endpoints (added statically so they show even if live spec fails to load)
  { method: "POST", path: "/vector/search", who: "Auth varies", bodySample: { target: "pets", query_embedding: [0.0,0.1,0.2], topK: 5, filter_ids: ["b5d11bb9-5ff9-4847-8e56-a03df24a519f"] }, description: "Semantic vector search for pets domain." },
  { method: "POST", path: "/vector/upsert", who: "Auth", bodySample: { target: "pets", items: [{ id: "b5d11bb9-5ff9-4847-8e56-a03df24a519f", embedding: [0.0,0.1,0.2] }] }, description: "Upsert embeddings for pets." },
  { method: "POST", path: "/vector/search", who: "Auth varies", notes: "KB semantic search", bodySample: { target: "kb", query_embedding: [0.0,0.1,0.2], topK: 5, filter_ids: ["d920ad16-2f7c-4a6e-99f2-44f925834a72"] }, description: "Semantic vector search for KB articles." },
  { method: "POST", path: "/vector/upsert", who: "Auth", notes: "KB embedding upsert", bodySample: { target: "kb", items: [{ id: "d920ad16-2f7c-4a6e-99f2-44f925834a72", embedding: [0.0,0.1,0.2] }] }, description: "Upsert embeddings for KB articles." },
    ],
  },
  {
    name: "Ratings & Feedback",
    items: [
      { method: "POST", path: "/sessions/:sessionId/ratings", who: "User", pathParams: ["sessionId"], bodySample: { score: 5, comment: "Great!" } },
      { method: "GET", path: "/vets/:vetId/ratings", who: "Public", pathParams: ["vetId"] },
      { method: "GET", path: "/sessions/:sessionId/ratings", who: "User/Vet/Admin", pathParams: ["sessionId"] },
    ],
  },
  {
    name: "Notifications",
    items: [
      { method: "POST", path: "/notifications/test", who: "Admin", bodySample: { channel: "email", to: "dev@localhost", subject: "Test" } },
      { method: "POST", path: "/notifications/receipt", who: "Admin", bodySample: { sessionId: "SESSION_UUID" } },
    ],
  },
  {
    name: "Files & Storage",
    items: [
      { method: "POST", path: "/files/signed-url", who: "User/Vet", bodySample: { path: "cases/abc.jpg" } },
      { method: "GET", path: "/files/download-url", who: "User/Vet", querySample: { path: "cases/abc.jpg" } },
    ],
  },
  {
    name: "Admin Ops",
    items: [
      { method: "GET", path: "/admin/users", who: "Admin", querySample: { q: "jorge" } },
      { method: "GET", path: "/admin/users/:userId", who: "Admin", pathParams: ["userId"] },
      { method: "GET", path: "/admin/subscriptions", who: "Admin", querySample: { status: "active" } },
      { method: "POST", path: "/admin/credits/grant", who: "Admin", bodySample: { user_id: "USER_UUID", chats: 2 } },
      { method: "POST", path: "/admin/refunds", who: "Admin", bodySample: { payment_id: "PAY_UUID" } },
      { method: "POST", path: "/admin/vets/:vetId/approve", who: "Admin", pathParams: ["vetId"] },
      { method: "POST", path: "/admin/plans", who: "Admin", bodySample: { code: "plus", price_mxn: 199 } },
      { method: "POST", path: "/admin/coupons", who: "Admin", bodySample: { code: "DEV50", percent_off: 50 } },
      { method: "GET", path: "/admin/analytics/usage", who: "Admin", querySample: { from: "2025-10-01", to: "2025-10-31" } },
    ],
  },
  {
    name: "Webhooks",
    items: [
      { method: "POST", path: "/webhooks/stripe", who: "Public (sig)", host: "webhooks", bodySample: { type: "checkout.session.completed" } },
      { method: "POST", path: "/internal/stripe/ingest", who: "Internal", host: "gateway", bodySample: { event: { type: "invoice.paid" } } },
    ],
  },
];

// Build a static lookup for enriching spec-derived endpoints
const STATIC_ENDPOINT_META: Record<string, Partial<Endpoint>> = (() => {
  const map: Record<string, Partial<Endpoint>> = {};
  for (const g of STATIC_GROUPS) {
    for (const ep of g.items) {
      const key = `${ep.method} ${ep.path}`;
      map[key] = { description: ep.description, who: ep.who, bodySample: ep.bodySample };
    }
  }
  return map;
})();

// Build endpoint groups from OpenAPI spec object
function buildGroupsFromOpenAPI(spec: any): EndpointGroup[] {
  if (!spec || !spec.paths) return [];
  const groupMap = new Map<string, Endpoint[]>();
  const paths = spec.paths as Record<string, any>;
  for (const [rawPath, item] of Object.entries(paths)) {
    for (const m of ["get","post","put","patch","delete"]) {
      const op = (item as any)[m];
      if (!op) continue;
      const method = m.toUpperCase() as HttpMethod;
      const tags = Array.isArray(op.tags) && op.tags.length ? op.tags : ["API"];
  const summary = op.summary || `${method} ${rawPath}`;
  const description = op.description || op.summary || undefined;
      const who = (op.security && op.security.length) ? "Auth" : "Public";
      // extract path params
      const paramNames: string[] = [];
      const braceMatches = Array.from(rawPath.matchAll(/\{(.*?)\}/g));
      for (const b of braceMatches) { if (b[1]) paramNames.push(b[1]); }
      // extract query params sample
      const querySample: Record<string, string> = {};
      if (Array.isArray(op.parameters)) {
        for (const p of op.parameters) {
          if (p?.in === 'query' && p?.name) {
            const defv = p?.schema?.default;
            querySample[p.name] = defv != null ? String(defv) : '';
          }
        }
      }
      // request body sample (very light heuristic)
      let bodySample: any = undefined;
      const rb = op.requestBody?.content?.['application/json']?.schema;
      if (rb && rb.type === 'object' && rb.properties) {
        bodySample = {};
        for (const [k, v] of Object.entries(rb.properties)) {
          const vv: any = v;
          if (vv?.default != null) bodySample[k] = vv.default;
          else if (vv?.type === 'string') bodySample[k] = '';
          else if (vv?.type === 'integer' || vv?.type === 'number') bodySample[k] = 0;
          else if (vv?.type === 'boolean') bodySample[k] = false;
        }
      }
      const basePath = rawPath.replace(/\{(.*?)\}/g, ':$1');
      const specKey = `${method} ${basePath}`;
      const staticMeta = STATIC_ENDPOINT_META[specKey] || {};
      const ep: Endpoint = {
        method,
        path: basePath,
        label: summary,
        who: staticMeta.who || who,
        status: ROUTE_STATUS[specKey] || 'todo',
        querySample: Object.keys(querySample).length ? querySample : undefined,
        pathParams: paramNames,
        bodySample: staticMeta.bodySample || bodySample,
        host: 'gateway',
        description: staticMeta.description || description,
      };
      for (const t of tags) {
        if (!groupMap.has(t)) groupMap.set(t, []);
        groupMap.get(t)!.push(ep);
      }
    }
  }
  // finalize
  return Array.from(groupMap.entries()).map(([name, items]) => ({ name, items }));
}

function buildUrl(base: string, endpoint: Endpoint, pathInputs: Record<string, string>, queryInputs: Record<string, string>) {
  // Preserve :param placeholders if missing to avoid generating // in URLs
  let path = endpoint.path;
  for (const [k, v] of Object.entries(pathInputs)) {
    if (v && v.trim().length) {
      path = path.replace(`:${k}`, encodeURIComponent(v));
    }
  }
  const qs = new URLSearchParams();
  for (const [k, v] of Object.entries(queryInputs)) {
    if (v != null && v !== "") qs.set(k, v);
  }
  const hasQs = Array.from(qs.keys()).length > 0;
  return base + path + (hasQs ? `?${qs.toString()}` : "");
}

async function doFetch(method: HttpMethod, url: string, headers: Record<string, string>, body?: any) {
  if (method === "WS") {
    throw new Error("WebSocket testing is not supported here.");
  }
  const init: RequestInit = {
    method,
    headers: {
      "content-type": body ? "application/json" : "application/json",
      ...headers,
    },
    body: body ? JSON.stringify(body) : undefined,
  };
  const res = await fetch(url, init as any);
  const text = await res.text();
  let json: any = null;
  try { json = text ? JSON.parse(text) : null; } catch {}
  return { ok: res.ok, status: res.status, json, text };
}

function Section({ title, children, description, descriptionClassName, className }: { title: string; children?: any; description?: string; descriptionClassName?: string; className?: string }) {
  return (
    <section className={`rounded-xl p-5 ${className ?? 'bg-zinc-950/60'}`}>
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-lg font-semibold text-zinc-100">{title}</h2>
        {description && <p className={`${descriptionClassName || 'text-sm'} text-zinc-400`}>{description}</p>}
      </div>
      {children}
    </section>
  );
}

function truncateToken(token?: string | null) {
  if (!token) return "<none>";
  if (token.length <= 48) return token;
  return `${token.slice(0, 20)}…${token.slice(-12)} (len:${token.length})`;
}

function Stat({ label, value, hint }: { label: string; value: string | number; hint?: string }) {
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900 p-4">
      <div className="text-sm text-zinc-400">{label}</div>
      <div className="text-2xl font-semibold text-zinc-100">{value}</div>
      {hint && <div className="text-xs text-zinc-500">{hint}</div>}
    </div>
  );
}

export default function ObservabilityCIPage() {
  const [env, setEnv] = useState<EnvKey>("local");
  const [gatewayUrl, setGatewayUrl] = useState(ENV_URLS.local.gateway);
  const [webhooksUrl, setWebhooksUrl] = useState(ENV_URLS.local.webhooks);
  const [ciUrl, setCiUrl] = useState<string>("");
  const [userId, setUserId] = useState(DEFAULT_TEST_USER);
  const [extraHeaders, setExtraHeaders] = useState("{}");
  const [bearerToken, setBearerToken] = useState<string>("");
  const [useIdem, setUseIdem] = useState<boolean>(false);
  const [idemKey, setIdemKey] = useState<string>("");
  const [activeSection, setActiveSection] = useState<"database" | "api" | "auth">("api");
  const bearerTokenIssue = useMemo(() => {
    const t = (bearerToken || '').trim();
    if (!t) return null;
    if (t.includes('…')) return 'Token looks truncated (contains …). Use the full value via Copy token.';
    const dotCount = (t.match(/\./g) || []).length;
    if (dotCount !== 2) return 'Expected a JWT with 3 segments (two dots).';
    if (t.length < 100) return 'Token seems too short; likely incomplete.';
    return null;
  }, [bearerToken]);
    /* ---------------- Auth & Sessions Debug (from home page) ---------------- */
    function authEventLog(level: "info" | "warn" | "error", msg: string, data?: any, ctx?: string) {
      const tag = `[auth:${level}]`;
      if (level === 'error') console.error(tag, ctx ? `(${ctx})` : '', msg, data || '');
      else if (level === 'warn') console.warn(tag, ctx ? `(${ctx})` : '', msg, data || '');
      else console.log(tag, ctx ? `(${ctx})` : '', msg, data || '');
      // Mirror into global Logs panel with API-like shape for visibility.
      const now = Date.now();
      setLogs((l) => [
        {
          kind: 'AUTH',
          ts: now,
          reqTs: now,
          resTs: now,
          method: 'AUTH',
          url: ctx ? `auth/${ctx}: ${msg}` : `auth: ${msg}`,
          status: level === 'error' ? 500 : 200,
          ok: level !== 'error',
          ms: 0,
          req: data && (level !== 'error') ? { body: typeof data === 'string' ? data : JSON.stringify(data).slice(0, 2000) } : undefined,
          res: level === 'error' && data ? { body: typeof data === 'string' ? data : JSON.stringify(data).slice(0, 2000) } : undefined,
        },
        ...l,
      ].slice(0, 300));
    }
    const [sbUrl, setSbUrl] = useState<string | undefined>(undefined);
    const [sbKey, setSbKey] = useState<string | undefined>(undefined);
    const [email, setEmail] = useState("lopezb.jl@gmail.com");
    const [password, setPassword] = useState("dev-password-123");
    const [authLoading, setAuthLoading] = useState(false);
    const [hasMountedAuth, setHasMountedAuth] = useState(false);
    const authMounted = useRef(false);
    const supabase: SupabaseClient | null = useMemo(() => {
      if (typeof window === 'undefined') return null;
      const finalUrl = sbUrl || process.env.NEXT_PUBLIC_SUPABASE_URL || '';
      const finalKey = sbKey || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || '';
      if (!finalUrl || !finalKey) return null;
      try {
        return createClient(finalUrl, finalKey, { auth: { persistSession: true, autoRefreshToken: true } });
      } catch {
        return null;
      }
    }, [sbUrl, sbKey]);
    const [session, setSession] = useState<Session | null>(null);
    const [user, setUser] = useState<User | null>(null);
    function summarizeSession(s: Session | null) {
      if (!s) return { session: null };
      const at = s.access_token;
      return {
        user_id: s.user.id,
        is_anonymous: (s.user as any).is_anonymous || false,
        expires_at: s.expires_at,
        access_token: at ? `${at.slice(0, 24)}…${at.slice(-16)} (len:${at.length})` : null,
        refresh_token: s.refresh_token ? s.refresh_token.slice(0, 12) : null
      };
    }
    useEffect(() => {
      if (authMounted.current) return;
      authMounted.current = true;
      setHasMountedAuth(true);
      if (typeof window !== 'undefined') {
        const envUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
        const envKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
        const storedUrl = window.localStorage.getItem('sb.url') || undefined;
        const storedKey = window.localStorage.getItem('sb.key') || undefined;
        setSbUrl(storedUrl || envUrl);
        setSbKey(storedKey || envKey);
        if (!(storedUrl || envUrl) || !(storedKey || envKey)) {
          authEventLog('warn', 'Missing Supabase config. Provide NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY, or fill them below.', { envUrl: !!envUrl, envKey: !!envKey, storedUrl: !!storedUrl, storedKey: !!storedKey }, 'env');
        }
      }
      if (!supabase) return;
      (async () => {
        const { data, error } = await supabase.auth.getSession();
        if (error) authEventLog('error', 'getSession failed', error, 'auth-init');
        else {
          setSession(data.session);
          if (data.session) authEventLog('info', 'Initial session', summarizeSession(data.session), 'auth-init');
          else authEventLog('info', 'No session at init', undefined, 'auth-init');
          if (data.session) {
            const u = await supabase.auth.getUser();
            if (u.error) authEventLog('error', 'getUser failed', u.error, 'auth-init'); else setUser(u.data.user);
          }
        }
      })();
      const lastEventRef = { key: '' } as { key: string };
      const { data: sub } = supabase.auth.onAuthStateChange((event: AuthChangeEvent, s: Session | null) => {
        setSession(s);
        const key = `${event}|${s?.user?.id || 'none'}|${s?.access_token?.slice(0,16) || 'no-token'}`;
        if (key !== lastEventRef.key) {
          authEventLog('info', `Auth event: ${event}`, summarizeSession(s), 'auth-state');
          lastEventRef.key = key;
        }
        setUser(s?.user || null);
      });
      return () => { sub.subscription.unsubscribe(); };
    }, [supabase]);
    async function signInEmail() {
      setAuthLoading(true);
      try {
        if (!supabase) { authEventLog('warn', 'Supabase client not initialized', undefined, 'email-password'); return; }
        if (!email || !password) { authEventLog('warn', 'Email and password required', undefined, 'email-password'); return; }
        const t0 = performance.now(); const reqTs = Date.now();
        const r1 = await supabase.auth.signInWithPassword({ email, password });
        if (r1.error) {
          authEventLog('warn', 'signInWithPassword failed, attempting signUp', r1.error, 'email-password');
          const t1 = performance.now(); const reqTs2 = Date.now();
          const r2 = await supabase.auth.signUp({ email, password });
          if (r2.error) throw r2.error;
          setLogs((l)=>[
            { kind: 'AUTH', ts: reqTs2, reqTs: reqTs2, resTs: reqTs2, method: 'AUTH', url: 'auth/supabase.signUp', status: 200, ok: true, ms: Math.round(performance.now()-t1), req: { body: JSON.stringify({ email: '<redacted>' }) }, res: { body: JSON.stringify(summarizeSession(r2.data.session), null, 2) } },
            ...l
          ].slice(0,300));
        } else {
          // success path handled by structured log below; avoid duplicate "Signed in" info event
        }
        // Push log for signInWithPassword
        setLogs((l)=>[
          { kind: 'AUTH', ts: reqTs, reqTs, resTs: reqTs, method: 'AUTH', url: 'auth/supabase.signInWithPassword', status: r1.error ? 400 : 200, ok: !r1.error, ms: Math.round(performance.now()-t0), req: { body: JSON.stringify({ email: '<redacted>' }) }, res: { body: JSON.stringify(summarizeSession(r1.data.session), null, 2) } },
          ...l
        ].slice(0,300));
      } catch (e) { authEventLog('error', 'Email/password auth error', e, 'email-password'); }
      finally { setAuthLoading(false); }
    }
    async function signInAnon() {
      setAuthLoading(true);
      try {
        if (!supabase) { authEventLog('warn', 'Supabase client not initialized', undefined, 'anonymous'); return; }
        const t0 = performance.now(); const reqTs = Date.now();
        const { data, error } = await supabase.auth.signInAnonymously();
        if (error) throw error;
        setLogs((l)=>[
          { kind: 'AUTH', ts: reqTs, reqTs, resTs: reqTs, method: 'AUTH', url: 'auth/supabase.signInAnonymously', status: 200, ok: true, ms: Math.round(performance.now()-t0), res: { body: JSON.stringify(summarizeSession(data.session), null, 2) } },
          ...l
        ].slice(0,300));
      } catch (e) { authEventLog('error', "Anonymous sign-in failed. Ensure 'Anonymous' provider is enabled in Supabase Auth.", e, 'anonymous'); }
      finally { setAuthLoading(false); }
    }
    async function signOutCurrent() {
      setAuthLoading(true);
      try {
        if (!supabase) { authEventLog('warn', 'Supabase client not initialized', undefined, 'signout'); return; }
        const t0 = performance.now(); const reqTs = Date.now();
        const { error } = await supabase.auth.signOut();
        if (error) throw error;
        setLogs((l)=>[
          { kind: 'AUTH', ts: reqTs, reqTs, resTs: reqTs, method: 'AUTH', url: 'auth/supabase.signOut', status: 200, ok: true, ms: Math.round(performance.now()-t0), res: { body: 'Signed out (current device)' } },
          ...l
        ].slice(0,300));
      } catch (e) { authEventLog('error', 'Sign out failed', e, 'signout'); }
      finally { setAuthLoading(false); }
    }
    async function callMe() {
      setAuthLoading(true);
      try {
        if (!supabase) { authEventLog('warn', 'Supabase client not initialized', undefined, 'GET /me'); return; }
        const current = (await supabase.auth.getSession()).data.session;
        if (!current) { authEventLog('warn', 'No session. Sign in first.', undefined, 'GET /me'); return; }
        const url = `${gatewayUrl}/me`;
        const headers = { Authorization: `Bearer ${current.access_token}` } as Record<string,string>;
        const t0 = performance.now(); const reqTs = Date.now();
        const res = await fetch(url, { headers });
        const ms = Math.round(performance.now()-t0);
        const body = await res.text();
        setLogs((l)=>[
          { kind: 'AUTH', ts: reqTs, reqTs, resTs: reqTs, method: 'GET', url, status: res.status, ok: res.ok, ms, req: { headers }, res: { body: body.slice(0,4000) } },
          ...l
        ].slice(0,300));
      } catch (e) { authEventLog('error', 'GET /me failed', e, 'GET /me'); }
      finally { setAuthLoading(false); }
    }
    async function copyToken() {
      try {
        if (!supabase) { authEventLog('warn', 'Supabase client not initialized', undefined, 'copy-token'); return; }
        const current = (await supabase.auth.getSession()).data.session;
        const token = current?.access_token || '';
        await navigator.clipboard.writeText(token);
        authEventLog('info', 'Access token copied to clipboard', { preview: token ? `${token.slice(0,16)}…` : '<none>' }, 'copy-token');
      } catch (e) { authEventLog('error', 'Copy token failed', e, 'copy-token'); }
    }
    async function listSessions() {
      setAuthLoading(true);
      try {
        if (!supabase) { authEventLog('warn', 'Supabase client not initialized', undefined, 'GET /me/security/sessions'); return; }
        const current = (await supabase.auth.getSession()).data.session;
        if (!current) { authEventLog('warn', 'No session. Sign in first.', undefined, 'GET /me/security/sessions'); return; }
        const url = `${gatewayUrl}/me/security/sessions`;
        const headers = { Authorization: `Bearer ${current.access_token}` } as Record<string,string>;
        const t0 = performance.now(); const reqTs = Date.now();
        const res = await fetch(url, { headers });
        const ms = Math.round(performance.now()-t0);
        const body = await res.text();
        setLogs((l)=>[
          { kind: 'AUTH', ts: reqTs, reqTs, resTs: reqTs, method: 'GET', url, status: res.status, ok: res.ok, ms, req: { headers }, res: { body: body.slice(0,4000) } },
          ...l
        ].slice(0,300));
      } catch (e) { authEventLog('error', 'GET /me/security/sessions failed', e, 'GET /me/security/sessions'); }
      finally { setAuthLoading(false); }
    }
    async function logoutAllApp() {
      setAuthLoading(true);
      try {
        if (!supabase) { authEventLog('warn', 'Supabase client not initialized', undefined, 'POST /me/security/logout-all'); return; }
        const current = (await supabase.auth.getSession()).data.session;
        if (!current) { authEventLog('warn', 'No session. Sign in first.', undefined, 'POST /me/security/logout-all'); return; }
        const url = `${gatewayUrl}/me/security/logout-all`;
        const headers = { Authorization: `Bearer ${current.access_token}` } as Record<string,string>;
        const t0 = performance.now(); const reqTs = Date.now();
        const res = await fetch(url, { method: 'POST', headers });
        const ms = Math.round(performance.now()-t0);
        const body = await res.text();
        setLogs((l)=>[
          { kind: 'AUTH', ts: reqTs, reqTs, resTs: reqTs, method: 'POST', url, status: res.status, ok: res.ok, ms, req: { headers }, res: { body: body.slice(0,4000) } },
          ...l
        ].slice(0,300));
      } catch (e) { authEventLog('error', 'POST /me/security/logout-all failed', e, 'POST /me/security/logout-all'); }
      finally { setAuthLoading(false); }
    }
    async function logoutAllSupabase() {
      setAuthLoading(true);
      try {
        if (!supabase) { authEventLog('warn', 'Supabase client not initialized', undefined, 'POST /me/security/logout-all-supabase'); return; }
        const current = (await supabase.auth.getSession()).data.session;
        if (!current) { authEventLog('warn', 'No session. Sign in first.', undefined, 'POST /me/security/logout-all-supabase'); return; }
        const url = `${gatewayUrl}/me/security/logout-all-supabase`;
        const headers = { Authorization: `Bearer ${current.access_token}` } as Record<string,string>;
        const t0 = performance.now(); const reqTs = Date.now();
        const res = await fetch(url, { method: 'POST', headers });
        const ms = Math.round(performance.now()-t0);
        const body = await res.text();
        setLogs((l)=>[
          { kind: 'AUTH', ts: reqTs, reqTs, resTs: reqTs, method: 'POST', url, status: res.status, ok: res.ok, ms, req: { headers }, res: { body: body.slice(0,4000) } },
          ...l
        ].slice(0,300));
      } catch (e) { authEventLog('error', 'POST /me/security/logout-all-supabase failed', e, 'POST /me/security/logout-all-supabase'); }
      finally { setAuthLoading(false); }
    }
  const [logs, setLogs] = useState<any[]>([]);
  const [useSpec, setUseSpec] = useState<boolean>(true);
  const [specGroups, setSpecGroups] = useState<EndpointGroup[] | null>(null);
  const [gwHealth, setGwHealth] = useState<{ ok: boolean | null; ms?: number; version?: string; time?: string; db?: 'connected'|'stub'|'error' }>({ ok: null });
  const [whHealth, setWhHealth] = useState<{ ok: boolean | null; ms?: number }>({ ok: null });
  const [ciStatus, setCiStatus] = useState<string>("unknown");

  const baseByHost = useMemo(() => ({
    gateway: gatewayUrl,
    webhooks: webhooksUrl,
  }), [gatewayUrl, webhooksUrl]);

  function switchEnv(e: EnvKey) {
    setEnv(e);
    setGatewayUrl(ENV_URLS[e].gateway);
    setWebhooksUrl(ENV_URLS[e].webhooks);
  }

  // Load OpenAPI spec and build groups
  useEffect(() => {
    let mounted = true;
    async function loadSpec() {
      try {
        const url = new URL('/openapi.yaml', gatewayUrl).toString();
        const text = await fetch(url, { cache: 'no-store' }).then(r => r.text());
        const spec = YAML.parse(text);
        const groups = buildGroupsFromOpenAPI(spec);
        if (mounted) setSpecGroups(groups);
      } catch {
        if (mounted) setSpecGroups(null);
      }
    }
    if (useSpec) loadSpec(); else setSpecGroups(null);
    return () => { mounted = false; };
  }, [gatewayUrl, useSpec]);

  function genUUIDv4() {
    const bytes = new Uint8Array(16);
    if (typeof crypto !== 'undefined' && (crypto as any).getRandomValues) {
      (crypto as any).getRandomValues(bytes);
    } else {
      for (let i = 0; i < 16; i++) bytes[i] = Math.floor(Math.random() * 256);
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant
    const toHex = (n: number) => n.toString(16).padStart(2, '0');
    const hex = Array.from(bytes, toHex).join('');
    return `${hex.substring(0,8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20)}`;
  }

  // health polling
  useEffect(() => {
    let mounted = true;
    async function pingHealth() {
      // Gateway /health
      try {
        const t0 = performance.now();
        const r = await fetch(new URL('/health', gatewayUrl).toString(), { cache: 'no-store' });
        const ms = Math.max(0, Math.round(performance.now() - t0));
        const ok = r.ok;
        let version: string | undefined; let timeStr: string | undefined;
        // Optional /version
        try { const vr = await fetch(new URL('/version', gatewayUrl).toString(), { cache: 'no-store' }); if (vr.ok) { const j = await vr.json().catch(()=>null); version = j?.version || j?.commit || j?.build || undefined; } } catch {}
        // Optional /time
        try { const tr = await fetch(new URL('/time', gatewayUrl).toString(), { cache: 'no-store' }); if (tr.ok) { const j = await tr.json().catch(()=>null); timeStr = j?.time || j?.now || undefined; } } catch {}
        // DB status via gateway diagnostics: prefer /_db/status; fall back to heuristic only if unavailable
        let dbStatus: 'connected'|'stub'|'error'|undefined = undefined;
        try {
          const sUrl = new URL('/_db/status', gatewayUrl).toString();
          const sRes = await fetch(sUrl, { cache: 'no-store' });
          if (sRes.ok) {
            const j = await sRes.json().catch(() => null);
            if (j && typeof j === 'object') {
              if (j.stub === false) dbStatus = 'connected';
              else if (j.stub === true) dbStatus = j.lastError ? 'error' : 'stub';
            }
          }
        } catch {
          // ignore; we'll try heuristic below
        }
        // Heuristic fallback (kept minimal): if gateway is healthy but we couldn't classify, assume connected
        if (!dbStatus && ok) dbStatus = 'connected';
        if (!dbStatus) dbStatus = 'error';
        if (mounted) setGwHealth({ ok, ms, version, time: timeStr, db: dbStatus });
      } catch {
        if (mounted) setGwHealth({ ok: false, db: 'error' });
      }
      // Webhooks /health
      try {
        const t0 = performance.now();
        const r = await fetch(new URL('/health', webhooksUrl).toString(), { cache: 'no-store' });
        const ms = Math.max(0, Math.round(performance.now() - t0));
        if (mounted) setWhHealth({ ok: r.ok, ms });
      } catch { if (mounted) setWhHealth({ ok: false }); }
    }
    pingHealth();
    const id = setInterval(pingHealth, 15000);
    return () => { mounted = false; clearInterval(id); };
  }, [gatewayUrl, webhooksUrl]);

  // CI status polling (optional URL)
  useEffect(() => {
    if (!ciUrl) { setCiStatus('unknown'); return; }
    let mounted = true;
    async function pingCI() {
      try {
        const r = await fetch(ciUrl, { cache: 'no-store' });
        const j = await r.json().catch(()=>null);
        let status: string = 'unknown';
        // Heuristics: GitHub Actions or generic
        const run = j?.workflow_runs?.[0] || j?.runs?.[0] || null;
        status = run?.conclusion || run?.status || j?.status || j?.state || (r.ok ? 'ok' : `http_${r.status}`);
        if (mounted) setCiStatus(String(status));
      } catch { if (mounted) setCiStatus('error'); }
    }
    pingCI();
    const id = setInterval(pingCI, 20000);
    return () => { mounted = false; clearInterval(id); };
  }, [ciUrl]);

  // logging helper for API tester
  function pushLog(entry: any) {
    setLogs((l) => [entry, ...l].slice(0, 300));
  }

  return (
    <div className="relative h-screen w-screen overflow-hidden bg-zinc-950 text-zinc-100">
      <div className="px-4 sm:px-6">
        {/* Header */}
        <div className="py-4">
          <h1 className="text-md text-zinc-200">Call a Vet Observability + CI</h1>
        </div>

  {/* Layout: left nav, main, right logs (single column on small, fixed logs width on large) */}
  <div className="grid grid-cols-1 lg:grid-cols-[380px_1fr_380px] gap-4 pb-28">
          {/* Left Sidebar */}
          <aside>
            <div className="sticky top-4 space-y-3">
              <nav className="rounded-xl border border-zinc-800 bg-zinc-900/60 p-4">
                <div className="mb-2 text-xs uppercase tracking-wide text-zinc-700">Sections</div>
                <div className="flex flex-col gap-2">
                  <button
                    aria-pressed={activeSection==='database'}
                    onClick={() => setActiveSection('database')}
                    className={`text-left text-sm transition focus:outline-none font-medium ${
                      activeSection==='database'
                        ? 'text-zinc-200'
                        : 'text-zinc-300 hover:text-zinc-100'
                    }`}
                  >
                    <span className="relative inline-block">
                      <span className="">Database</span>
                      {activeSection==='database' && (
                        <span aria-hidden className="absolute inset-0 bg-gradient-to-r from-emerald-300 to-cyan-300 bg-clip-text text-transparent">
                          Database
                        </span>
                      )}
                    </span>
                  </button>
                  <button
                    aria-pressed={activeSection==='api'}
                    onClick={() => setActiveSection('api')}
                    className={`text-left text-sm transition focus:outline-none font-medium ${
                      activeSection==='api'
                        ? 'text-zinc-200'
                        : 'text-zinc-300 hover:text-zinc-100'
                    }`}
                  >
                    <span className="relative inline-block">
                      <span className="">API testing</span>
                      {activeSection==='api' && (
                        <span aria-hidden className="absolute inset-0 bg-gradient-to-r from-emerald-300 to-cyan-300 bg-clip-text text-transparent">
                          API testing
                        </span>
                      )}
                    </span>
                  </button>
                  <button
                    aria-pressed={activeSection==='auth'}
                    onClick={() => setActiveSection('auth')}
                    className={`text-left text-sm transition focus:outline-none font-medium ${
                      activeSection==='auth'
                        ? 'text-zinc-200'
                        : 'text-zinc-300 hover:text-zinc-100'
                    }`}
                  >
                    <span className="relative inline-block">
                      <span className="">Auth & Sessions</span>
                      {activeSection==='auth' && (
                        <span aria-hidden className="absolute inset-0 bg-gradient-to-r from-emerald-300 to-cyan-300 bg-clip-text text-transparent">
                          Auth & Sessions
                        </span>
                      )}
                    </span>
                  </button>
                </div>
              </nav>

              {/* Request settings moved from main */}
              <div className="rounded-xl border border-zinc-800 bg-zinc-900/60 p-4">
                <div className="mb-2 text-xs uppercase tracking-wide text-zinc-700">Request settings</div>
                <div className="space-y-3">
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">Gateway URL</label>
                    <input value={gatewayUrl} onChange={(e) => setGatewayUrl(e.target.value)} className="w-full rounded-md border-0 bg-zinc-950 px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-emerald-700/40" />
                  </div>
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">Webhooks URL</label>
                    <input value={webhooksUrl} onChange={(e) => setWebhooksUrl(e.target.value)} className="w-full rounded-md border-0 bg-zinc-950 px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-emerald-700/40" />
                  </div>
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">CI status URL (optional)</label>
                    <input value={ciUrl} onChange={(e) => setCiUrl(e.target.value)} className="w-full rounded-md border-0 bg-zinc-950 px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-emerald-700/40" />
                  </div>
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">x-user-id (dev)</label>
                    <input value={userId} onChange={(e) => setUserId(e.target.value)} className="w-full rounded-md border-0 bg-zinc-950 px-3 py-2 text-sm outline-none focus:ring-1 focus:ring-emerald-700/40" />
                  </div>
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">Bearer token (Authorization)</label>
                    <input value={bearerToken} onChange={(e) => setBearerToken(e.target.value)} placeholder="eyJhbGciOi..." className="w-full rounded-md border-0 bg-zinc-950 px-3 py-2 text-sm font-mono outline-none focus:ring-1 focus:ring-emerald-700/40" />
                    {bearerTokenIssue && (
                      <div className="mt-1 text-[10px] text-amber-300">{bearerTokenIssue}</div>
                    )}
                  </div>
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">Idempotency-Key</label>
                    <div className="flex items-center gap-2">
                      <label className="inline-flex items-center gap-2 text-xs text-zinc-300">
                        <input type="checkbox" checked={useIdem} onChange={(e) => setUseIdem(e.target.checked)} />
                        Use header
                      </label>
                      <button onClick={() => setIdemKey(genUUIDv4())} className="rounded border border-zinc-700 bg-zinc-800 px-2 py-1 text-xs hover:bg-zinc-700">New</button>
                    </div>
                    <input value={idemKey} onChange={(e) => setIdemKey(e.target.value)} placeholder="auto-generate or paste a UUID" className="mt-1 w-full rounded-md border-0 bg-zinc-950 px-3 py-2 text-xs font-mono outline-none focus:ring-1 focus:ring-emerald-700/40" />
                  </div>
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">Extra headers (JSON)</label>
                    <input value={extraHeaders} onChange={(e) => setExtraHeaders(e.target.value)} className="w-full rounded-md border-0 bg-zinc-950 px-3 py-2 text-sm font-mono outline-none focus:ring-1 focus:ring-emerald-700/40" />
                  </div>
                </div>
              </div>
            </div>
          </aside>

          {/* Main content */}
          <main className={`space-y-6 overflow-y-auto h-[calc(100vh-150px)] pr-1 rounded-xl border border-zinc-800  p-4 ${activeSection==='auth' ? 'bg-zinc-900/70' : ''}`}>
            {activeSection === 'database' ? (
              <Section title="Database (structure)" description="Tables & fields">
                <div className="grid gap-2 text-sm text-zinc-300">
                  <div className="rounded-md border border-zinc-800 bg-zinc-900 p-3"><div className="font-medium">users</div><div className="text-xs text-zinc-400">id, email, name, role, created_at</div></div>
                  <div className="rounded-md border border-zinc-800 bg-zinc-900 p-3"><div className="font-medium">pets</div><div className="text-xs text-zinc-400">id, user_id, name, species, birthdate, notes</div></div>
                  <div className="rounded-md border border-zinc-800 bg-zinc-900 p-3"><div className="font-medium">user_subscriptions</div><div className="text-xs text-zinc-400">id, user_id, plan_code, current_period_start, current_period_end, status</div></div>
                  <div className="rounded-md border border-zinc-800 bg-zinc-900 p-3"><div className="font-medium">subscription_usage</div><div className="text-xs text-zinc-400">subscription_id, included_chats, consumed_chats, included_videos, consumed_videos</div></div>
                  <div className="rounded-md border border-zinc-800 bg-zinc-900 p-3"><div className="font-medium">chat_sessions</div><div className="text-xs text-zinc-400">id, user_id, vet_id, status, started_at, ended_at</div></div>
                  <div className="rounded-md border border-zinc-800 bg-zinc-900 p-3"><div className="font-medium">messages</div><div className="text-xs text-zinc-400">id, session_id, role, content, created_at</div></div>
                  <div className="rounded-md border border-zinc-800 bg-zinc-900 p-3"><div className="font-medium">payments / invoices</div><div className="text-xs text-zinc-400">id, user_id, amount, currency, status, metadata</div></div>
                </div>
              </Section>
            ) : activeSection === 'api' ? (
              <Section title="API testing" description="Grouped endpoints with live calls" descriptionClassName="text-xs">
                <div className="mb-3 flex items-center justify-between">
                  <label className="inline-flex items-center gap-2 text-xs text-zinc-300" title="Fetch /openapi.yaml to build dynamic endpoint list; uncheck to use static fallback">
                    <input type="checkbox" checked={useSpec} onChange={(e) => setUseSpec(e.target.checked)} />
                    Use live API blueprint (OpenAPI)
                  </label>
                  <span className="text-[11px] text-zinc-500">{useSpec ? (specGroups ? `${specGroups.length} groups` : 'loading…') : 'using static list'}</span>
                </div>
                <ApiTester groups={useSpec && specGroups ? specGroups : STATIC_GROUPS} baseByHost={baseByHost} userId={userId} extraHeaders={extraHeaders} bearerToken={bearerToken} useIdem={useIdem} idemKey={idemKey} onGlobalLog={(e) => pushLog(e)} />
              </Section>
            ) : (
              <Section title="Auth & Sessions" description="Supabase auth flows and security endpoints" descriptionClassName="text-xs" className="bg-zinc-900/80">
                <div className="space-y-6">
                  {/* Config */}
                  <div className="grid gap-4 sm:grid-cols-3">
                    <div>
                      <label className="mb-1 block text-xs text-zinc-400">Supabase URL</label>
                      <input value={sbUrl || ''} onChange={(e)=>{ setSbUrl(e.target.value); if (typeof window!=='undefined') window.localStorage.setItem('sb.url', e.target.value);} } className="w-full rounded-md border-0 bg-zinc-950 px-3 py-2 text-xs outline-none focus:ring-1 focus:ring-emerald-700/40" />
                    </div>
                    <div>
                      <label className="mb-1 block text-xs text-zinc-400">Anon key</label>
                      <input value={sbKey || ''} onChange={(e)=>{ setSbKey(e.target.value); if (typeof window!=='undefined') window.localStorage.setItem('sb.key', e.target.value);} } className="w-full rounded-md border-0 bg-zinc-950 px-3 py-2 text-xs outline-none focus:ring-1 focus:ring-emerald-700/40" />
                    </div>
                    {/* auto-saved, no explicit save button */}
                  </div>
                  {/* Email/password */}
                  <div className="grid gap-4 sm:grid-cols-3">
                    <div>
                      <label className="mb-1 block text-xs text-zinc-400">Email</label>
                      <input value={email} onChange={(e)=>setEmail(e.target.value)} className="w-full rounded-md border-0 bg-zinc-950 px-3 py-2 text-xs outline-none focus:ring-1 focus:ring-emerald-700/40" />
                    </div>
                    <div>
                      <label className="mb-1 block text-xs text-zinc-400">Password</label>
                      <input type="password" value={password} onChange={(e)=>setPassword(e.target.value)} className="w-full rounded-md border-0 bg-zinc-950 px-3 py-2 text-xs outline-none focus:ring-1 focus:ring-emerald-700/40" />
                    </div>
                    <div className="flex items-end gap-2" />
                  </div>
                  {/* Actions */}
                  <div className="grid gap-2 sm:grid-cols-3">
                    <button disabled={authLoading} onClick={signInEmail} className="rounded-md bg-emerald-600 px-3 py-2 text-xs font-semibold text-white hover:bg-emerald-500 disabled:opacity-50">{authLoading ? 'Working…' : 'Login / Sign-up'}</button>
                    <button disabled={authLoading} onClick={signInAnon} className="rounded-md bg-zinc-800 px-3 py-2 text-xs text-zinc-100 hover:bg-zinc-700 disabled:opacity-50">Anon</button>
                    <button disabled={authLoading} onClick={signOutCurrent} className="rounded-md bg-zinc-800 px-3 py-2 text-xs text-zinc-100 hover:bg-zinc-700 disabled:opacity-50">Logout</button>
                    <button disabled={authLoading} onClick={callMe} className="rounded-md bg-zinc-800 px-3 py-2 text-xs text-zinc-100 hover:bg-zinc-700 disabled:opacity-50">GET /me</button>
                    <button disabled={authLoading} onClick={copyToken} className="rounded-md bg-zinc-800 px-3 py-2 text-xs text-zinc-100 hover:bg-zinc-700 disabled:opacity-50">Copy token</button>
                    <button disabled={authLoading} onClick={listSessions} className="rounded-md bg-zinc-800 px-3 py-2 text-xs text-zinc-100 hover:bg-zinc-700 disabled:opacity-50">List sessions</button>
                    <button disabled={authLoading} onClick={logoutAllApp} className="rounded-md bg-zinc-800 px-3 py-2 text-xs text-zinc-100 hover:bg-zinc-700 disabled:opacity-50">Logout all (soft)</button>
                    <button disabled={authLoading} onClick={logoutAllSupabase} className="rounded-md bg-zinc-800 px-3 py-2 text-xs text-zinc-100 hover:bg-zinc-700 disabled:opacity-50">Logout all (Supabase)</button>
                    <div className="rounded-md border border-zinc-800 bg-zinc-950 p-2 text-[10px] text-zinc-400">Client initialized: {hasMountedAuth ? String(!!supabase) : '…'}</div>
                  </div>
                  <p className="text-[10px] text-zinc-500">Soft logout revokes app-tracked sessions; Supabase global logout invalidates refresh tokens.</p>
                  {/* Current user/session */}
                  <div className="mt-4 rounded-lg border border-zinc-800 bg-zinc-950 p-4">
                    <h4 className="mb-2 text-sm font-medium text-zinc-200">Current user/session</h4>
                    <div className="grid gap-1 text-sm text-zinc-300">
                      <div>User ID: {user?.id ?? "<none>"}</div>
                      <div>Email: {user?.email ?? "<none>"}</div>
                      <div>Anonymous: {String(((user as any)?.is_anonymous) ?? ((user?.app_metadata as any)?.provider === 'anon'))}</div>
                      <div>Access Token: {truncateToken(session?.access_token)}</div>
                      <div>Expires At: {session?.expires_at ?? '-'}</div>
                    </div>
                  </div>
                </div>
              </Section>
            )}
          </main>

          {/* Right Sidebar (Logs) */}
          <aside>
            <div className="sticky top-4 h-[calc(100vh-150px)] overflow-auto rounded-xl border border-zinc-800 bg-black/50 p-3">
              <LogsPanel logs={logs as any} />
            </div>
          </aside>
        </div>
      </div>

      {/* Bottom status bar */}
      <div className="fixed bottom-0 left-0 right-0 border-t border-zinc-800 bg-zinc-950/90 backdrop-blur">
        <div className="px-4">
          <div className="flex items-center justify-between gap-4 py-2 text-xs">
            <div className="flex items-center gap-2">
              <span className="text-zinc-400">Env:</span>
              <div className="overflow-hidden rounded-md border border-zinc-800">
                <div className="flex">
                  {(["local", "staging", "production"] as EnvKey[]).map((k) => (
                    <button
                      key={k}
                      onClick={() => switchEnv(k)}
                      className={`px-2.5 py-1 text-[11px] transition focus:outline-none focus-visible:ring-1 focus-visible:ring-emerald-500 ${
                        env === k ? 'bg-gradient-to-r from-emerald-600 to-teal-600 text-white shadow-inner' : 'bg-zinc-900 text-zinc-200 hover:bg-zinc-800'
                      }`}
                    >
                      {k}
                    </button>
                  ))}
                </div>
              </div>
            </div>
            <div className="hidden sm:block h-4 w-px bg-zinc-800" />
            <div className="flex items-center gap-2">
              <span className="text-zinc-400">Metrics:</span>
              <span className={`rounded px-1 ${gwHealth.ok ? 'bg-emerald-900/40 text-emerald-300' : gwHealth.ok === false ? 'bg-rose-900/40 text-rose-300' : 'bg-zinc-800 text-zinc-300'}`}>GW {gwHealth.ms ?? '—'}ms</span>
              <span className={`rounded px-1 ${whHealth.ok ? 'bg-emerald-900/40 text-emerald-300' : whHealth.ok === false ? 'bg-rose-900/40 text-rose-300' : 'bg-zinc-800 text-zinc-300'}`}>WH {whHealth.ms ?? '—'}ms</span>
              <span className={`rounded px-1 ${gwHealth.db === 'connected' ? 'bg-emerald-900/40 text-emerald-300' : gwHealth.db === 'stub' ? 'bg-yellow-900/40 text-yellow-300' : gwHealth.db === 'error' ? 'bg-rose-900/40 text-rose-300' : 'bg-zinc-800 text-zinc-300'}`}>DB {gwHealth.db || '—'}</span>
            </div>
            <div className="hidden sm:block h-4 w-px bg-zinc-800" />
            <div className="flex items-center gap-2">
              <span className="text-zinc-400">Traces:</span>
              <span className="rounded bg-zinc-800 px-1 text-zinc-300">—</span>
            </div>
            <div className="hidden sm:block h-4 w-px bg-zinc-800" />
            <div className="flex items-center gap-2">
              <span className="text-zinc-400">CI:</span>
              <span className={`rounded px-1 ${ciStatus.includes('ok') || ciStatus.includes('success') ? 'bg-emerald-900/40 text-emerald-300' : ciStatus.includes('error') || ciStatus.includes('fail') ? 'bg-rose-900/40 text-rose-300' : 'bg-zinc-800 text-zinc-300'}`}>{ciStatus}</span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function LogsPanel({ logs }: { logs: Array<any> }) {
  const [copied, setCopied] = useState(false);
  const [filter, setFilter] = useState<'ALL'|'API'|'AUTH'>('ALL');
  const [beautify, setBeautify] = useState<boolean>(true);
  const filtered = useMemo(() => {
    if (filter === 'ALL') return logs;
    return logs.filter((l) => (l.kind || (l.method === 'AUTH' ? 'AUTH' : 'API')) === filter);
  }, [logs, filter]);
  async function copyAllLogs() {
    try {
      const parts: string[] = [];
      for (const l of filtered) {
        const lines: string[] = [];
        lines.push(`[${l.method}] ${l.url}`);
        lines.push(`Status: ${l.status} ${l.ok ? 'OK' : 'ERR'} (${l.ms} ms)`);
        if (l.reqTs || l.resTs || l.ts) {
          const reqStr = l.reqTs ? new Date(l.reqTs).toISOString() : (l.ts ? new Date(l.ts).toISOString() : '');
          const resStr = l.resTs ? new Date(l.resTs).toISOString() : (l.ts ? new Date(l.ts).toISOString() : '');
          lines.push(`Times: req=${reqStr} res=${resStr}`);
        }
        if (l.req?.headers) {
          lines.push(`\nRequest headers:`);
          lines.push(beautify ? JSON.stringify(l.req.headers, null, 2) : JSON.stringify(l.req.headers));
        }
        if (l.req?.body) {
          lines.push(`\nRequest body:`);
          if (typeof l.req.body === 'string') {
            if (beautify) {
              try { lines.push(JSON.stringify(JSON.parse(l.req.body), null, 2)); }
              catch { lines.push(l.req.body); }
            } else {
              lines.push(l.req.body);
            }
          } else {
            lines.push(beautify ? JSON.stringify(l.req.body, null, 2) : JSON.stringify(l.req.body));
          }
        }
        if (l.res?.body != null) {
          lines.push(`\nResponse body:`);
          if (typeof l.res.body === 'string') {
            if (beautify) {
              try { lines.push(JSON.stringify(JSON.parse(l.res.body), null, 2)); }
              catch { lines.push(l.res.body); }
            } else {
              lines.push(l.res.body);
            }
          } else {
            lines.push(beautify ? JSON.stringify(l.res.body, null, 2) : JSON.stringify(l.res.body));
          }
        }
        parts.push(lines.join('\n'));
      }
      const text = parts.join('\n\n-----------------------------\n\n');
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {}
  }
  return (
    <div className="flex h-full flex-col">
      <div className="mb-2 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className="text-sm font-medium">Logs</div>
          <div className="rounded-md border border-zinc-800">
            <div className="flex overflow-hidden">
              {(['ALL','API','AUTH'] as const).map(k => (
                <button key={k} onClick={()=>setFilter(k)} className={`px-1.5 py-0.5 text-[10px] ${filter===k ? 'bg-zinc-700 text-white' : 'bg-zinc-900 text-zinc-300 hover:bg-zinc-800'}`}>{k}</button>
              ))}
            </div>
          </div>
          <button onClick={()=>setBeautify(b=>!b)} className={`rounded px-1.5 py-0.5 text-[10px] ${beautify ? 'bg-emerald-900/40 text-emerald-300' : 'bg-zinc-800 text-zinc-300 hover:bg-zinc-700'}`} title="Beautify JSON in logs">
            {beautify ? 'Beautify: ON' : 'Beautify: OFF'}
          </button>
        </div>
        <button
          onClick={copyAllLogs}
          className={`inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] ${copied ? 'bg-emerald-900/40 text-emerald-300' : 'bg-zinc-800 text-zinc-300 hover:bg-zinc-700'}`}
          title={copied ? 'Copied!' : 'Copy all logs'}
        >
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <rect x="9" y="9" width="12" height="12" rx="2" className={`${copied ? 'fill-emerald-300/80' : 'fill-zinc-300/80'}`}/>
            <rect x="3" y="3" width="12" height="12" rx="2" className={`${copied ? 'fill-emerald-200/70' : 'fill-zinc-200/70'}`}/>
          </svg>
          <span>{copied ? 'Copied' : 'Copy all'}</span>
        </button>
      </div>
      <div className="min-h-0 flex-1 overflow-auto">
        <LogList logs={filtered} beautify={beautify} />
      </div>
    </div>
  );
}

function ApiTester({ groups, baseByHost, userId, extraHeaders, bearerToken, useIdem, idemKey, onGlobalLog }: { groups: EndpointGroup[]; baseByHost: Record<string, string>; userId: string; extraHeaders: string; bearerToken: string; useIdem: boolean; idemKey: string; onGlobalLog: (e: any) => void }) {
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const [results, setResults] = useState<Record<string, { status: number; ok: boolean; body: string }>>({});

  function toggle(name: string) {
    setExpanded((s) => ({ ...s, [name]: !s[name] }));
  }

  return (
    <div className="space-y-4">
      <h3 className="text-sm font-medium text-zinc-300">API routes</h3>
      <div className="my-5 h-px w-full" />
      <div className="rounded-xl bg-zinc-900/60 p-3">
        <div className="max-h-[55vh] md:max-h-[60vh] xl:max-h-[65vh] overflow-y-auto pr-2">
          <div className="flex flex-col gap-3">
            {groups.map((g, gi) => (
              <div key={g.name} className="mb-2">
                <button
                  className="group relative w-full text-left py-1"
                  onClick={() => toggle(g.name)}
                >
                  <span className="inline-flex items-center gap-2">
                    <svg
                      className={`h-3 w-3 transition-transform duration-200 ${expanded[g.name] ? 'rotate-90' : ''}`}
                      viewBox="0 0 20 20" fill="currentColor"
                    >
                      <path fillRule="evenodd" d="M7.21 14.77a.75.75 0 0 1-1.06-1.06L9.86 10 6.15 6.29a.75.75 0 1 1 1.06-1.06l4.24 4.24a.75.75 0 0 1 0 1.06l-4.24 4.24z" clipRule="evenodd" />
                    </svg>
                    <span className="relative inline-block text-sm">
                      <span className="text-zinc-200">{g.name}</span>
                      <span aria-hidden className="absolute inset-0 whitespace-nowrap bg-gradient-to-r from-emerald-300 to-cyan-300 bg-clip-text text-transparent w-0 overflow-hidden transition-[width] duration-300 ease-out group-hover:w-full">
                        {g.name}
                      </span>
                    </span>
                  </span>
                  {/* Hover fill effect now applied directly to text above */}
                </button>
                {/* Animated container for routes */}
                <div
                  className={`mt-2 overflow-hidden transition-all duration-200 ease-out ${expanded[g.name] ? 'opacity-100 translate-y-0' : 'max-h-0 opacity-0 -translate-y-1'}`}
                >
                  <div className="space-y-2">
                    {g.items.map((ep, ei) => (
                      <div key={`${ep.method}:${ep.path}:${ep.notes || ep.label || ep.description || ''}:${ei}`}>
                        {/* Divider between routes (except first) */}
                        {ei > 0 && <div className="my-2 h-px w-full bg-zinc-800" />}
                        <div
                          className={`transition-all duration-200 ease-out ${expanded[g.name] ? 'opacity-100 translate-y-0' : 'opacity-0 translate-y-1'}`}
                          style={{ transitionDelay: expanded[g.name] ? `${Math.min(ei * 30, 300)}ms` : '0ms' }}
                        >
                          <EndpointRow
                            ep={ep}
                            baseByHost={baseByHost}
                            userId={userId}
                            extraHeaders={extraHeaders}
                            bearerToken={bearerToken}
                            useIdem={useIdem}
                            idemKey={idemKey}
                            onResult={(body, ok, status) => setResults((r) => ({ ...r, [g.name + ei]: { body, ok, status } }))}
                            result={results[g.name + ei]}
                            onGlobalLog={onGlobalLog}
                          />
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

function EndpointRow({ ep, baseByHost, userId, extraHeaders, bearerToken, useIdem, idemKey, onResult, result, onGlobalLog }: {
  ep: Endpoint;
  baseByHost: Record<string, string>;
  userId: string;
  extraHeaders: string;
  bearerToken: string;
  useIdem: boolean;
  idemKey: string;
  onResult: (body: string, ok: boolean, status: number) => void;
  result?: { status: number; ok: boolean; body: string };
  onGlobalLog: (e: any) => void;
}) {
  const [paths, setPaths] = useState<Record<string, string>>(() => Object.fromEntries((ep.pathParams || []).map((k) => [k, ""])));
  const [query, setQuery] = useState<Record<string, string>>(() => ({ ...(ep.querySample || {}) } as Record<string, string>));
  const [body, setBody] = useState<string>(() => (ep.bodySample ? JSON.stringify(ep.bodySample, null, 2) : ""));
  const [loading, setLoading] = useState(false);
  const [loadingSample, setLoadingSample] = useState(false);

  const host = ep.host || "gateway";
  const base = baseByHost[host] || "";
  const url = buildUrl(base, ep, paths, query);
  const effectiveStatus = ep.status || ROUTE_STATUS[`${ep.method} ${ep.path}`];

  async function run() {
    setLoading(true);
    try {
      let parsedHeaders: Record<string, string> = {};
      try { parsedHeaders = JSON.parse(extraHeaders || "{}"); } catch {
        // ignore JSON errors
      }
      const headers: Record<string, string> = {
        ...parsedHeaders,
      };
      // Auto admin override for KB publish route when no explicit x-admin header supplied
      if (ep.path.includes('/kb/') && ep.path.endsWith('/publish') && !headers['x-admin']) {
        headers['x-admin'] = '1';
      }
      if (bearerToken && bearerToken.trim()) {
        const t = bearerToken.trim();
        const dotCount = (t.match(/\./g) || []).length;
        if (t.includes('…') || dotCount !== 2 || t.length < 100) {
          throw new Error('Invalid Bearer token: value looks truncated or malformed. Use the full token via Copy token in Auth & Sessions.');
        }
        headers["authorization"] = `Bearer ${t}`;
      }
      else if (host === "gateway") headers["x-user-id"] = userId;
      if (useIdem) headers["idempotency-key"] = (idemKey && idemKey.trim()) ? idemKey.trim() : '';
      let parsedBody: any = undefined;
      if (body && body.trim().length) {
        try { parsedBody = JSON.parse(body); } catch (e) { throw new Error("Body is not valid JSON"); }
      }
      const t0 = performance.now();
      const reqTs = Date.now();
      const res = await doFetch(ep.method, url, headers, parsedBody);
      const ms = Math.max(0, Math.round(performance.now() - t0));
      const resTs = reqTs + ms;
      const pretty = res.json ? JSON.stringify(res.json, null, 2) : (res.text || "");
      onResult(pretty, res.ok, res.status);
      onGlobalLog({
        kind: 'API',
        ts: reqTs,
        reqTs,
        resTs,
        method: ep.method,
        url,
        status: res.status,
        ok: res.ok,
        ms,
        req: { headers, body: parsedBody ? JSON.stringify(parsedBody).slice(0, 2000) : undefined },
        res: { body: pretty.slice(0, 4000) }
      });
    } catch (e: any) {
      onResult(e?.message || String(e), false, 0);
      const now = Date.now();
      onGlobalLog({ kind: 'API', ts: now, reqTs: now, resTs: now, method: ep.method, url, status: 0, ok: false, ms: 0, error: e?.message || String(e) });
    } finally {
      setLoading(false);
    }
  }

  // Load JSON sample from /observability-ci/requests based on heuristic slug
  async function loadSample() {
    setLoadingSample(true);
    try {
      // Slug strategy: method-path with slashes turned to dashes and params removed
      const slug = (() => {
        const method = ep.method.toLowerCase();
        const base = ep.path.replace(/:\w+/g, '').replace(/^\/+/,'').replace(/\/+$/,'').replace(/\//g, '-');
        // hand-tuned aliases
        if (ep.path === '/sessions/start') return 'sessions-start';
        if (ep.path.endsWith('/messages')) return 'message-append';
        if (ep.path === '/pets') return 'pet-create';
        if (ep.path === '/subscriptions/usage' || ep.path === '/subscriptions/usage/current') return 'subscriptions-usage';
        // differentiate vector kb vs pets samples
        if (ep.path === '/vector/search' && ep.bodySample?.target === 'kb') return 'vector-search-kb';
        if (ep.path === '/vector/upsert' && ep.bodySample?.target === 'kb') return 'vector-upsert-kb';
        return `${base || 'root'}`;
      })();
      const url = `/observability-ci/requests/${slug}.json`;
      const res = await fetch(url, { cache: 'no-store' });
      if (!res.ok) {
        // If not found, fall back to built-in bodySample (if any) and log
        setBody(ep.bodySample ? JSON.stringify(ep.bodySample, null, 2) : '');
        return;
      }
      const ctype = res.headers.get('content-type') || '';
      const txt = await res.text();
      if (ctype.includes('application/json')) {
        // pretty-print JSON
        try { setBody(JSON.stringify(JSON.parse(txt), null, 2)); }
        catch { setBody(txt); }
      } else {
        // Unexpected content (likely HTML 404). Keep existing or fallback to bodySample
        setBody(ep.bodySample ? JSON.stringify(ep.bodySample, null, 2) : '');
      }
    } catch {
      // Network or other error: keep existing or fallback
      setBody(ep.bodySample ? JSON.stringify(ep.bodySample, null, 2) : '');
    }
    finally { setLoadingSample(false); }
  }

  return (
    <div className="grid grid-cols-1 gap-3 p-4 md:grid-cols-3">
      <div className="space-y-2">
        <div className="flex items-center gap-2" title={ep.description || ep.notes || ''}>
          <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${
            ep.method === "GET" ? "bg-emerald-900/40 text-emerald-300" :
            ep.method === "POST" ? "bg-sky-900/40 text-sky-300" :
            ep.method === "PUT" ? "bg-indigo-900/40 text-indigo-300" :
            ep.method === "PATCH" ? "bg-yellow-900/40 text-yellow-300" :
            ep.method === "DELETE" ? "bg-rose-900/40 text-rose-300" : "bg-zinc-800 text-zinc-300"
          }`}>{ep.method}</span>
          <code className="rounded bg-zinc-900 px-2 py-0.5 text-xs text-zinc-200">{ep.path}</code>
          {effectiveStatus && (
            <span className={`inline-flex items-center rounded px-1.5 py-0.5 text-[10px] ${effectiveStatus==='done' ? 'bg-emerald-900/40 text-emerald-300' : 'bg-zinc-800 text-zinc-300'}`}>
              {effectiveStatus === 'done' ? 'DONE' : 'TODO'}
            </span>
          )}
        </div>
        {ep.description && (
          <div className="text-xs text-zinc-400/90 leading-snug" title={ep.description}>
            {ep.description}
          </div>
        )}
        {ep.who && <div className="text-xs text-zinc-400">{ep.who}</div>}
        <div className="text-[10px] text-zinc-500">Host: {host}</div>
        <div className="text-[10px] text-zinc-500 break-all">URL: {url}</div>
        {/* Body editor moved to full-width row below */}
      </div>
      <div className="space-y-2">
        {(ep.pathParams && ep.pathParams.length > 0) && (
          <div className="grid grid-cols-2 gap-2">
            {ep.pathParams!.map((k) => (
              <div key={k}>
                <label className="mb-1 block text-xs text-zinc-400">{k}</label>
                <input value={paths[k] || ""} onChange={(e) => setPaths((s) => ({ ...s, [k]: e.target.value }))} className="w-full rounded-md border-0 bg-zinc-950 px-2 py-1.5 text-xs outline-none focus:ring-1 focus:ring-emerald-700/40" />
              </div>
            ))}
          </div>
        )}
        {(ep.querySample && Object.keys(ep.querySample).length > 0) && (
          <div className="grid grid-cols-2 gap-2">
            {Object.keys(ep.querySample!).map((k) => (
              <div key={k}>
                <label className="mb-1 block text-xs text-zinc-400">{k}</label>
                <input value={query[k] || ""} onChange={(e) => setQuery((s) => ({ ...s, [k]: e.target.value }))} className="w-full rounded-md border-0 bg-zinc-950 px-2 py-1.5 text-xs outline-none focus:ring-1 focus:ring-emerald-700/40" />
              </div>
            ))}
          </div>
        )}
        
      </div>
      <div className="space-y-2">
        <div className="flex items-center justify-end">
          {ep.method !== 'GET' && (
            <button onClick={loadSample} disabled={loadingSample} className={`mr-2 rounded-md px-2 py-1 text-xs ${loadingSample ? 'bg-zinc-700 text-zinc-300' : 'bg-zinc-800 text-zinc-200 hover:bg-zinc-700'}`}>Load sample</button>
          )}
          {(() => {
            const missingParam = ep.pathParams?.some((k) => !paths[k] || !paths[k].trim());
            const disabled = loading || (!!ep.pathParams && ep.pathParams.length > 0 && missingParam);
            return (
              <button
                onClick={run}
                disabled={disabled}
                title={disabled && missingParam ? 'Fill all path params first' : ''}
                className={`rounded-md px-3 py-1.5 text-sm ${disabled ? 'bg-zinc-700 text-zinc-300' : 'bg-emerald-600 text-white hover:bg-emerald-500'}`}
              >
                {loading ? 'Running…' : missingParam ? 'Params needed' : 'Send'}
              </button>
            );
          })()}
        </div>
        {result && (
          <div className="flex justify-end">
            <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs ${result.ok ? "bg-emerald-900/40 text-emerald-300" : "bg-rose-900/40 text-rose-300"}`}>
              {result.ok ? "OK" : "ERR"} {result.status || ""}
            </span>
          </div>
        )}
      </div>
      {(ep.method !== 'GET') && (
        <div className="md:col-span-3 rounded-md border border-zinc-800 bg-zinc-950 p-2">
          <div className="mb-1 text-[10px] text-zinc-400">Body (JSON)</div>
          <textarea
            value={body}
            onChange={(e) => setBody(e.target.value)}
            rows={8}
            className="w-full resize-none rounded-sm border-0 bg-transparent px-1 py-1 text-[10px] font-mono text-zinc-200 outline-none max-h-40 overflow-auto whitespace-pre-wrap break-all"
          />
        </div>
      )}
      {result && (
        <div className="md:col-span-3 rounded-md border border-zinc-800 bg-zinc-950 p-2">
          <div className="mb-1 text-[10px] text-zinc-400">Response</div>
          <pre className="max-h-40 max-w-full overflow-auto whitespace-pre-wrap break-all text-[10px] text-zinc-300">{result.body}</pre>
        </div>
      )}
    </div>
  );
}

function LogList({ logs, beautify }: { logs: Array<any>; beautify: boolean }) {
  return (
    <div className="space-y-3">
      {(!logs || logs.length === 0) && <div className="text-xs text-zinc-500">No logs yet. Run an API call.</div>}
      {logs.map((l, i) => (
        <LogCard key={i} l={l} beautify={beautify} />
      ))}
    </div>
  );
}

function LogCard({ l, beautify }: { l: any; beautify: boolean }) {
  const [copied, setCopied] = useState(false);
  async function copyAll() {
    try {
      const pieces: string[] = [];
      pieces.push(`[${l.method}] ${l.url}`);
      pieces.push(`Status: ${l.status} ${l.ok ? 'OK' : 'ERR'} (${l.ms} ms)`);
      if (l.reqTs || l.resTs) {
        const reqStr = l.reqTs ? new Date(l.reqTs).toISOString() : new Date(l.ts).toISOString();
        const resStr = l.resTs ? new Date(l.resTs).toISOString() : new Date(l.ts).toISOString();
        pieces.push(`Times: req=${reqStr} res=${resStr}`);
      }
      if (l.req?.headers) {
        pieces.push(`\nRequest headers:`);
        pieces.push(beautify ? JSON.stringify(l.req.headers, null, 2) : JSON.stringify(l.req.headers));
      }
      if (l.req?.body) {
        pieces.push(`\nRequest body:`);
        if (typeof l.req.body === 'string') {
          if (beautify) { try { pieces.push(JSON.stringify(JSON.parse(l.req.body), null, 2)); } catch { pieces.push(l.req.body); } }
          else { pieces.push(l.req.body); }
        } else {
          pieces.push(beautify ? JSON.stringify(l.req.body, null, 2) : JSON.stringify(l.req.body));
        }
      }
      if (l.res?.body != null) {
        pieces.push(`\nResponse body:`);
        if (typeof l.res.body === 'string') {
          if (beautify) { try { pieces.push(JSON.stringify(JSON.parse(l.res.body), null, 2)); } catch { pieces.push(l.res.body); } }
          else { pieces.push(l.res.body); }
        } else {
          pieces.push(beautify ? JSON.stringify(l.res.body, null, 2) : JSON.stringify(l.res.body));
        }
      }
      const text = pieces.join('\n');
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {}
  }
  return (
    <div className="space-y-2 rounded-lg bg-zinc-900 p-2">
      <div className="flex items-center justify-between">
        <div className="flex min-w-0 items-center gap-2">
          <span className="rounded bg-zinc-800/70 px-1 py-0.5 text-[10px]">{l.method}</span>
          {l.kind && <span className={`rounded px-1 py-0.5 text-[10px] ${l.kind==='AUTH' ? 'bg-purple-900/40 text-purple-300' : 'bg-slate-900/40 text-slate-300'}`}>{l.kind}</span>}
          <div className="truncate text-xs text-zinc-300" title={l.url}>{l.url}</div>
        </div>
        <div className="flex items-center gap-2">
          <span className={`rounded px-1 py-0.5 text-[10px] ${l.ok ? 'bg-emerald-900/40 text-emerald-300' : 'bg-rose-900/40 text-rose-300'}`}>{l.status}</span>
        </div>
      </div>
      {l.error && (
        <div className="rounded-md bg-rose-950/40 p-2 text-xs text-rose-200">{l.error}</div>
      )}
      {l.req && (
        <div className="grid gap-1 text-[11px]">
          <div className="text-zinc-400">Request</div>
          <div className="rounded bg-zinc-950 p-2">
            <div className="text-zinc-500">Headers</div>
            <pre className="max-w-full overflow-auto whitespace-pre-wrap break-all text-[10px] text-zinc-300">{beautify ? JSON.stringify(l.req.headers, null, 2) : JSON.stringify(l.req.headers)}</pre>
          </div>
          {l.req.body && (
            <div className="rounded bg-zinc-950 p-2">
              <div className="text-zinc-500">Body</div>
              <pre className="max-w-full overflow-auto whitespace-pre-wrap break-all text-[10px] text-zinc-300">{(() => {
                if (typeof l.req.body === 'string') {
                  if (!beautify) return l.req.body;
                  try { return JSON.stringify(JSON.parse(l.req.body), null, 2); } catch { return l.req.body; }
                }
                return beautify ? JSON.stringify(l.req.body, null, 2) : JSON.stringify(l.req.body);
              })()}</pre>
            </div>
          )}
        </div>
      )}
      {l.res && (
        <div className="grid gap-1 text-[11px]">
          <div className="flex items-center justify-between text-zinc-400">
            <span>Response</span>
            <button
              onClick={copyAll}
              className={`inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[10px] ${copied ? 'bg-emerald-900/40 text-emerald-300' : 'bg-zinc-800 text-zinc-300 hover:bg-zinc-700'}`}
              title={copied ? 'Copied!' : 'Copy request + response'}
            >
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
                <rect x="9" y="9" width="12" height="12" rx="2" className={`${copied ? 'fill-emerald-300/80' : 'fill-zinc-300/80'}`}/>
                <rect x="3" y="3" width="12" height="12" rx="2" className={`${copied ? 'fill-emerald-200/70' : 'fill-zinc-200/70'}`}/>
              </svg>
              <span>{copied ? 'Copied' : 'Copy all'}</span>
            </button>
          </div>
          <div className="rounded bg-zinc-950 p-2">
            <pre className="max-h-56 max-w-full overflow-auto whitespace-pre-wrap break-all text-[10px] text-zinc-300">{(() => {
              if (typeof l.res.body === 'string') {
                if (!beautify) return l.res.body;
                try { return JSON.stringify(JSON.parse(l.res.body), null, 2); } catch { return l.res.body; }
              }
              return beautify ? JSON.stringify(l.res.body, null, 2) : JSON.stringify(l.res.body);
            })()}</pre>
          </div>
        </div>
      )}
      <div className="flex items-center justify-between text-[10px] text-zinc-400">
        <span>Req: <span className="font-mono">{new Date(l.reqTs || l.ts).toLocaleTimeString()}</span></span>
        <span>Res: <span className="font-mono">{new Date(l.resTs || l.ts).toLocaleTimeString()}</span> ({l.ms} ms)</span>
      </div>
    </div>
  );
}
