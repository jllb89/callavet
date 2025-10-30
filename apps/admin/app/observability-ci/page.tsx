"use client";

import { useEffect, useMemo, useState } from "react";
import YAML from "yaml";

type HttpMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "WS";
type EnvKey = "local" | "staging" | "production";

type Endpoint = {
  method: HttpMethod;
  path: string; // e.g. /pets/:petId
  label?: string;
  who?: string; // visibility
  notes?: string;
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
      { method: "GET", path: "/me", who: "User/Vet/Admin" },
      { method: "PATCH", path: "/me", who: "User/Vet/Admin", bodySample: { name: "Jane Doe", timezone: "America/Mexico_City" } },
      { method: "GET", path: "/me/security/sessions", who: "User/Vet/Admin" },
      { method: "POST", path: "/me/security/logout-all", who: "User/Vet/Admin" },
      { method: "GET", path: "/me/billing-profile", who: "User/Vet/Admin" },
      { method: "PUT", path: "/me/billing-profile", who: "User/Vet/Admin", bodySample: { tax_id: "XAXX010101000", address: { line1: "Av. Siempre Viva 123" } } },
      { method: "POST", path: "/me/billing/payment-method/attach", who: "User/Vet", bodySample: { return_url: "http://localhost:3000" } },
      { method: "DELETE", path: "/me/billing/payment-method/:pmId", who: "User/Vet", pathParams: ["pmId"], bodySample: {} },
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
      { method: "GET", path: "/kb", who: "Public", querySample: { species: "dog" } },
      { method: "GET", path: "/kb/:id", who: "Public", pathParams: ["id"] },
      { method: "POST", path: "/kb", who: "Admin/Vet", bodySample: { title: "Vomiting", content: "..." } },
      { method: "GET", path: "/search", who: "Auth varies", querySample: { q: "rash", type: "kb" } },
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
      const ep: Endpoint = {
        method,
        path: rawPath.replace(/\{(.*?)\}/g, ':$1'),
        label: summary,
        who,
        querySample: Object.keys(querySample).length ? querySample : undefined,
        pathParams: paramNames,
        bodySample,
        host: 'gateway'
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
  let path = endpoint.path;
  for (const [k, v] of Object.entries(pathInputs)) {
    path = path.replace(`:${k}`, encodeURIComponent(v || ""));
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

function Section({ title, children, description, descriptionClassName }: { title: string; children?: any; description?: string; descriptionClassName?: string }) {
  return (
    <section className="rounded-xl border border-zinc-800 bg-zinc-950/60 p-5 shadow-sm">
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-lg font-semibold text-zinc-100">{title}</h2>
        {description && <p className={`${descriptionClassName || 'text-sm'} text-zinc-400`}>{description}</p>}
      </div>
      {children}
    </section>
  );
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
  const [activeSection, setActiveSection] = useState<"database" | "api">("api");
  const [logs, setLogs] = useState<any[]>([]);
  const [useSpec, setUseSpec] = useState<boolean>(true);
  const [specGroups, setSpecGroups] = useState<EndpointGroup[] | null>(null);
  const [gwHealth, setGwHealth] = useState<{ ok: boolean | null; ms?: number; version?: string; time?: string }>({ ok: null });
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
        if (mounted) setGwHealth({ ok, ms, version, time: timeStr });
      } catch {
        if (mounted) setGwHealth({ ok: false });
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

        {/* Layout: left nav, main, right logs (full-width grid) */}
        <div className="grid grid-cols-12 gap-4 pb-28">
          {/* Left Sidebar */}
          <aside className="col-span-12 sm:col-span-3 lg:col-span-2">
            <div className="sticky top-4 space-y-2">
              <nav className="rounded-xl border border-zinc-800 bg-zinc-900/60 p-3">
                <div className="mb-4 text-xs uppercase tracking-wide text-zinc-700">Sections</div>
                <div className="overflow-hidden rounded-lg border border-zinc-800">
                  <div className="flex">
                    <button
                      aria-pressed={activeSection==='database'}
                      onClick={() => setActiveSection('database')}
                      className={`flex-1 items-center gap-2 px-3 py-2 text-sm transition focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 ${
                        activeSection==='database'
                          ? 'bg-gradient-to-r from-emerald-600 to-teal-600 text-white shadow-inner'
                          : 'bg-zinc-900 text-zinc-200 hover:bg-zinc-800'
                      }`}
                    >
                      <span className="mr-2 inline-block align-middle">{/* DB icon */}
                        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" className="inline">
                          <ellipse cx="12" cy="5" rx="8" ry="3" className={`${activeSection==='database' ? 'fill-white/90' : 'fill-zinc-300/70'}`}/>
                          <path d="M4 5v6c0 1.66 3.58 3 8 3s8-1.34 8-3V5" className={`${activeSection==='database' ? 'fill-white/90' : 'fill-zinc-300/70'}`}/>
                          <path d="M4 11v6c0 1.66 3.58 3 8 3s8-1.34 8-3v-6" className={`${activeSection==='database' ? 'fill-white/90' : 'fill-zinc-300/70'}`}/>
                        </svg>
                      </span>
                      Database
                    </button>
                    <button
                      aria-pressed={activeSection==='api'}
                      onClick={() => setActiveSection('api')}
                      className={`flex-1 items-center gap-2 px-3 py-2 text-sm transition focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500 ${
                        activeSection==='api'
                          ? 'bg-gradient-to-r from-emerald-600 to-teal-600 text-white shadow-inner'
                          : 'bg-zinc-900 text-zinc-200 hover:bg-zinc-800'
                      }`}
                    >
                      <span className="mr-2 inline-block align-middle">{/* API icon */}
                        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" className="inline">
                          <circle cx="6" cy="12" r="2" className={`${activeSection==='api' ? 'fill-white/90' : 'fill-zinc-300/70'}`}/>
                          <circle cx="18" cy="6" r="2" className={`${activeSection==='api' ? 'fill-white/90' : 'fill-zinc-300/70'}`}/>
                          <circle cx="18" cy="18" r="2" className={`${activeSection==='api' ? 'fill-white/90' : 'fill-zinc-300/70'}`}/>
                          <path d="M7.7 10.7l8.6-4.4M7.7 13.3l8.6 4.4" strokeWidth="1.5" className={`${activeSection==='api' ? 'stroke-white/90' : 'stroke-zinc-300/70'}`}/>
                        </svg>
                      </span>
                      API testing
                    </button>
                  </div>
                </div>
              </nav>
            </div>
          </aside>

          {/* Main content */}
          <main className="col-span-12 sm:col-span-6 lg:col-span-8 space-y-6 overflow-y-auto h-[calc(100vh-150px)] pr-1">
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
            ) : (
              <Section title="API testing" description="Grouped endpoints with live calls" descriptionClassName="text-xs">
                {/* Request settings inline (URLs, headers) */}
                <div className="mb-4 grid gap-3 sm:grid-cols-2">
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">Gateway URL</label>
                    <input value={gatewayUrl} onChange={(e) => setGatewayUrl(e.target.value)} className="w-full rounded-md border border-zinc-800 bg-zinc-900 px-3 py-2 text-sm outline-none focus:border-emerald-500" />
                  </div>
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">Webhooks URL</label>
                    <input value={webhooksUrl} onChange={(e) => setWebhooksUrl(e.target.value)} className="w-full rounded-md border border-zinc-800 bg-zinc-900 px-3 py-2 text-sm outline-none focus:border-emerald-500" />
                  </div>
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">CI status URL (optional)</label>
                    <input value={ciUrl} onChange={(e) => setCiUrl(e.target.value)} className="w-full rounded-md border border-zinc-800 bg-zinc-900 px-3 py-2 text-sm outline-none focus:border-emerald-500" />
                  </div>
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">x-user-id (dev)</label>
                    <input value={userId} onChange={(e) => setUserId(e.target.value)} className="w-full rounded-md border border-zinc-800 bg-zinc-900 px-3 py-2 text-sm outline-none focus:border-emerald-500" />
                  </div>
                  <div>
                    <label className="mb-1 block text-xs text-zinc-400">Bearer token (Authorization)</label>
                    <input value={bearerToken} onChange={(e) => setBearerToken(e.target.value)} placeholder="eyJhbGciOi..." className="w-full rounded-md border border-zinc-800 bg-zinc-900 px-3 py-2 text-sm font-mono outline-none focus:border-emerald-500" />
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
                    <input value={idemKey} onChange={(e) => setIdemKey(e.target.value)} placeholder="auto-generate or paste a UUID" className="mt-1 w-full rounded-md border border-zinc-800 bg-zinc-900 px-3 py-2 text-xs font-mono outline-none focus:border-emerald-500" />
                  </div>
                  <div className="sm:col-span-2">
                    <label className="mb-1 block text-xs text-zinc-400">Extra headers (JSON)</label>
                    <input value={extraHeaders} onChange={(e) => setExtraHeaders(e.target.value)} className="w-full rounded-md border border-zinc-800 bg-zinc-900 px-3 py-2 text-sm font-mono outline-none focus:border-emerald-500" />
                  </div>
                </div>
                <div className="mb-3 flex items-center justify-between">
                  <label className="inline-flex items-center gap-2 text-xs text-zinc-300">
                    <input type="checkbox" checked={useSpec} onChange={(e) => setUseSpec(e.target.checked)} />
                    Load live spec (/openapi.yaml)
                  </label>
                  <span className="text-[11px] text-zinc-500">{useSpec ? (specGroups ? `${specGroups.length} groups` : 'loading…') : 'using static list'}</span>
                </div>
                <ApiTester groups={useSpec && specGroups ? specGroups : STATIC_GROUPS} baseByHost={baseByHost} userId={userId} extraHeaders={extraHeaders} bearerToken={bearerToken} useIdem={useIdem} idemKey={idemKey} onGlobalLog={(e) => pushLog(e)} />
              </Section>
            )}
          </main>

          {/* Right Sidebar (Logs) */}
          <aside className="col-span-12 sm:col-span-3 lg:col-span-2">
            <div className="sticky top-4 h-[calc(100vh-150px)] overflow-auto rounded-xl border border-zinc-800 bg-black/50 p-3">
              <div className="mb-2 text-sm font-medium">Logs</div>
              <LogList logs={logs as any} />
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

function ApiTester({ groups, baseByHost, userId, extraHeaders, bearerToken, useIdem, idemKey, onGlobalLog }: { groups: EndpointGroup[]; baseByHost: Record<string, string>; userId: string; extraHeaders: string; bearerToken: string; useIdem: boolean; idemKey: string; onGlobalLog: (e: any) => void }) {
  const [expanded, setExpanded] = useState<Record<string, boolean>>({});
  const [results, setResults] = useState<Record<string, { status: number; ok: boolean; body: string }>>({});

  function toggle(name: string) {
    setExpanded((s) => ({ ...s, [name]: !s[name] }));
  }

  return (
    <div className="space-y-4">
      {/* Divider before routes */}
      <div className="my-6 h-px w-full bg-zinc-800" />
      <h3 className="text-sm font-medium text-zinc-300">API routes</h3>
      <div className="max-h-[55vh] md:max-h-[60vh] xl:max-h-[65vh] overflow-y-auto pr-2">
        <div className="columns-1 md:columns-2 gap-4 [column-fill:balance]">
          {groups.map((g, gi) => (
            <div key={gi} className="mb-4 break-inside-avoid overflow-hidden rounded-xl border border-zinc-800">
              <button className="flex w-full items-center justify-between bg-zinc-900 px-4 py-3 text-left hover:bg-zinc-800" onClick={() => toggle(g.name)}>
                <div className="font-medium">{g.name}</div>
                <div className="text-xs text-zinc-400">{expanded[g.name] ? "Hide" : "Show"}</div>
              </button>
              {expanded[g.name] && (
                <div className="divide-y divide-zinc-800">
                  {g.items.map((ep, ei) => (
                    <EndpointRow
                      key={ei}
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
                  ))}
                </div>
              )}
            </div>
          ))}
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

  const host = ep.host || "gateway";
  const base = baseByHost[host] || "";
  const url = buildUrl(base, ep, paths, query);

  async function run() {
    setLoading(true);
    try {
      let parsedHeaders: Record<string, string> = {};
      try { parsedHeaders = JSON.parse(extraHeaders || "{}"); } catch {
        // ignore JSON errors
      }
      const headers: Record<string, string> = {
        ...(host === "gateway" ? { "x-user-id": userId } : {}),
        ...parsedHeaders,
      };
      if (bearerToken && bearerToken.trim()) headers["authorization"] = `Bearer ${bearerToken.trim()}`;
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
      onGlobalLog({ ts: now, reqTs: now, resTs: now, method: ep.method, url, status: 0, ok: false, ms: 0, error: e?.message || String(e) });
    } finally {
      setLoading(false);
    }
  }

  return (
    <div className="grid grid-cols-1 gap-3 p-4 md:grid-cols-3">
      <div className="space-y-2">
        <div className="flex items-center gap-2">
          <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${
            ep.method === "GET" ? "bg-emerald-900/40 text-emerald-300" :
            ep.method === "POST" ? "bg-sky-900/40 text-sky-300" :
            ep.method === "PUT" ? "bg-indigo-900/40 text-indigo-300" :
            ep.method === "PATCH" ? "bg-yellow-900/40 text-yellow-300" :
            ep.method === "DELETE" ? "bg-rose-900/40 text-rose-300" : "bg-zinc-800 text-zinc-300"
          }`}>{ep.method}</span>
          <code className="rounded bg-zinc-900 px-2 py-0.5 text-xs text-zinc-200">{ep.path}</code>
        </div>
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
                <input value={paths[k] || ""} onChange={(e) => setPaths((s) => ({ ...s, [k]: e.target.value }))} className="w-full rounded-md border border-zinc-800 bg-zinc-900 px-2 py-1.5 text-xs outline-none focus:border-emerald-500" />
              </div>
            ))}
          </div>
        )}
        {(ep.querySample && Object.keys(ep.querySample).length > 0) && (
          <div className="grid grid-cols-2 gap-2">
            {Object.keys(ep.querySample!).map((k) => (
              <div key={k}>
                <label className="mb-1 block text-xs text-zinc-400">{k}</label>
                <input value={query[k] || ""} onChange={(e) => setQuery((s) => ({ ...s, [k]: e.target.value }))} className="w-full rounded-md border border-zinc-800 bg-zinc-900 px-2 py-1.5 text-xs outline-none focus:border-emerald-500" />
              </div>
            ))}
          </div>
        )}
        
      </div>
      <div className="space-y-2">
        <div className="flex items-center justify-end">
          <button onClick={run} disabled={loading} className={`rounded-md px-3 py-1.5 text-sm ${loading ? "bg-zinc-700 text-zinc-300" : "bg-emerald-600 text-white hover:bg-emerald-500"}`}>
            {loading ? "Running…" : "Send"}
          </button>
        </div>
        {result && (
          <div className="flex justify-end">
            <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs ${result.ok ? "bg-emerald-900/40 text-emerald-300" : "bg-rose-900/40 text-rose-300"}`}>
              {result.ok ? "OK" : "ERR"} {result.status || ""}
            </span>
          </div>
        )}
      </div>
      {(ep.bodySample != null) && (
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

function LogList({ logs }: { logs: Array<any> }) {
  return (
    <div className="space-y-3">
      {(!logs || logs.length === 0) && <div className="text-xs text-zinc-500">No logs yet. Run an API call.</div>}
      {logs.map((l, i) => (
        <LogCard key={i} l={l} />
      ))}
    </div>
  );
}

function LogCard({ l }: { l: any }) {
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
        pieces.push(JSON.stringify(l.req.headers, null, 2));
      }
      if (l.req?.body) {
        pieces.push(`\nRequest body:`);
        pieces.push(typeof l.req.body === 'string' ? l.req.body : JSON.stringify(l.req.body, null, 2));
      }
      if (l.res?.body != null) {
        pieces.push(`\nResponse body:`);
        pieces.push(typeof l.res.body === 'string' ? l.res.body : JSON.stringify(l.res.body, null, 2));
      }
      const text = pieces.join('\n');
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1200);
    } catch {}
  }
  return (
    <div className="space-y-2 rounded-lg border border-zinc-800 bg-zinc-900 p-2">
      <div className="flex items-center justify-between">
        <div className="flex min-w-0 items-center gap-2">
          <span className="rounded bg-zinc-800 px-1 py-0.5 text-[10px]">{l.method}</span>
          <div className="truncate text-xs text-zinc-300" title={l.url}>{l.url}</div>
        </div>
        <div className="flex items-center gap-2">
          <span className={`rounded px-1 py-0.5 text-[10px] ${l.ok ? 'bg-emerald-900/40 text-emerald-300' : 'bg-rose-900/40 text-rose-300'}`}>{l.status}</span>
        </div>
      </div>
      {l.error && (
        <div className="rounded-md border border-rose-900/40 bg-rose-950/40 p-2 text-xs text-rose-200">{l.error}</div>
      )}
      {l.req && (
        <div className="grid gap-1 text-[11px]">
          <div className="text-zinc-400">Request</div>
          <div className="rounded border border-zinc-800 bg-zinc-950 p-2">
            <div className="text-zinc-500">Headers</div>
            <pre className="max-w-full overflow-auto whitespace-pre-wrap break-all text-[10px] text-zinc-300">{JSON.stringify(l.req.headers, null, 2)}</pre>
          </div>
          {l.req.body && (
            <div className="rounded border border-zinc-800 bg-zinc-950 p-2">
              <div className="text-zinc-500">Body</div>
              <pre className="max-w-full overflow-auto whitespace-pre-wrap break-all text-[10px] text-zinc-300">{l.req.body}</pre>
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
          <div className="rounded border border-zinc-800 bg-zinc-950 p-2">
            <pre className="max-h-56 max-w-full overflow-auto whitespace-pre-wrap break-all text-[10px] text-zinc-300">{l.res.body}</pre>
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
