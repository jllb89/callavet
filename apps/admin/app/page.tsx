"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import Image from "next/image";
import { createClient, type Session, type User, type AuthChangeEvent, type SupabaseClient } from "@supabase/supabase-js";

// Minimal in-page logger
type LogEntry = { t: number; level: "info" | "warn" | "error"; msg: string; data?: any; ctx?: string };
function useLogger() {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const log = (level: LogEntry["level"], msg: string, data?: any, ctx?: string) => {
    const entry: LogEntry = { t: Date.now(), level, msg, data, ctx };
    setLogs((l) => [entry, ...l].slice(0, 200));
    // Mirror to console
    const tag = `[auth:${level}]`;
    if (level === "error") console.error(tag, ctx ? `(${ctx})` : "", msg, data ?? "");
    else if (level === "warn") console.warn(tag, ctx ? `(${ctx})` : "", msg, data ?? "");
    else console.log(tag, ctx ? `(${ctx})` : "", msg, data ?? "");
  };
  return { logs, log };
}

function truncateToken(token?: string | null) {
  if (!token) return "<none>";
  if (token.length <= 48) return token;
  return `${token.slice(0, 20)}…${token.slice(-12)} (len:${token.length})`;
}

export default function Home() {
  const { logs, log } = useLogger();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [gatewayUrl, setGatewayUrl] = useState(
    process.env.NEXT_PUBLIC_GATEWAY_URL || "http://localhost:4000"
  );
  // Supabase config (runtime editable for dev/testing)
  const [sbUrl, setSbUrl] = useState<string | undefined>(undefined);
  const [sbKey, setSbKey] = useState<string | undefined>(undefined);
  const [user, setUser] = useState<User | null>(null);
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(false);
  const [hasMounted, setHasMounted] = useState(false);
  const mounted = useRef(false);

  const supabase = useMemo<SupabaseClient | null>(() => {
    // Avoid constructing client during SSR/prerender. Only init in browser.
    if (typeof window === "undefined") return null;
    const url = sbUrl || process.env.NEXT_PUBLIC_SUPABASE_URL;
    const key = sbKey || process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    if (!url || !key) return null;
    return createClient(url, key);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sbUrl, sbKey]);

  // Track auth state changes and initial session
  useEffect(() => {
    if (mounted.current) return;
    mounted.current = true;
    setHasMounted(true);
    // After mount, hydrate sbUrl/sbKey from localStorage or env
    if (typeof window !== "undefined") {
      const envUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
      const envKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
      const storedUrl = window.localStorage.getItem("sb.url") || undefined;
      const storedKey = window.localStorage.getItem("sb.key") || undefined;
      const finalUrl = storedUrl || envUrl;
      const finalKey = storedKey || envKey;
      setSbUrl(finalUrl);
      setSbKey(finalKey);
      if (!finalUrl || !finalKey) {
        log(
          "warn",
          "Missing Supabase config. Provide NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY, or fill them below.",
          { envUrl: !!envUrl, envKey: !!envKey, storedUrl: !!storedUrl, storedKey: !!storedKey },
          "env"
        );
      }
    }
    if (!supabase) return;
    (async () => {
      const { data, error } = await supabase.auth.getSession();
      if (error) {
        log("error", "getSession failed", error, "auth-init");
      } else {
        setSession(data.session);
        if (data.session) {
          log("info", "Initial session", summarizeSession(data.session), "auth-init");
          // Only ask for user if we actually have a session to avoid noisy AuthSessionMissingError
          const u = await supabase.auth.getUser();
          if (u.error) log("error", "getUser failed", u.error, "auth-init");
          else setUser(u.data.user);
        } else {
          setUser(null);
          log("info", "No session at init", undefined, "auth-init");
        }
      }
    })();

    const lastEventRef = { key: "" } as { key: string };
    const { data: sub } = supabase.auth.onAuthStateChange((event: AuthChangeEvent, s: Session | null) => {
      setSession(s);
      const key = `${event}|${s?.user?.id || "none"}|${s?.access_token?.slice(0,16) || "no-token"}`;
      // Deduplicate identical consecutive events (esp. repeated SIGNED_OUT null session spam)
      if (key !== lastEventRef.key) {
        log("info", `Auth event: ${event}`, summarizeSession(s), "auth-state");
        lastEventRef.key = key;
      }
      if (s?.user) setUser(s.user);
      else setUser(null);
    });
    return () => sub.subscription.unsubscribe();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function summarizeSession(s?: Session | null) {
    if (!s) return { session: null };
    return {
      user_id: s.user?.id,
      is_anonymous: s.user?.is_anonymous ?? (s.user?.app_metadata as any)?.provider === "anon",
      expires_at: s.expires_at,
      access_token: truncateToken(s.access_token),
      refresh_token: truncateToken((s as any).refresh_token),
    };
  }

  const signInEmailPassword = async () => {
    setLoading(true);
    try {
      if (!supabase) {
        log("warn", "Supabase client not initialized", undefined, "email-password");
        return;
      }
      if (!email || !password) {
        log("warn", "Email and password required", undefined, "email-password");
        return;
      }
      // Try sign-in, if fails with invalid creds, attempt sign-up
      const r1 = await supabase.auth.signInWithPassword({ email, password });
      if (r1.error) {
        log("warn", "signInWithPassword failed, attempting signUp", r1.error, "email-password");
        const r2 = await supabase.auth.signUp({ email, password });
        if (r2.error) throw r2.error;
        log("info", "Sign-up initiated (email confirmation may be required)", r2.data, "email-password");
      } else {
        log("info", "Signed in", summarizeSession(r1.data.session), "email-password");
      }
    } catch (e) {
      log("error", "Email/password auth error", e, "email-password");
    } finally {
      setLoading(false);
    }
  };

  const signInAnonymous = async () => {
    setLoading(true);
    try {
      if (!supabase) {
        log("warn", "Supabase client not initialized", undefined, "anonymous");
        return;
      }
      const { data, error } = await supabase.auth.signInAnonymously();
      if (error) throw error;
      log("info", "Anonymous sign-in", summarizeSession(data.session), "anonymous");
    } catch (e) {
      log(
        "error",
        "Anonymous sign-in failed. Ensure 'Anonymous' provider is enabled in Supabase Auth.",
        e,
        "anonymous"
      );
    } finally {
      setLoading(false);
    }
  };

  const signOut = async () => {
    setLoading(true);
    try {
      if (!supabase) {
        log("warn", "Supabase client not initialized", undefined, "signout");
        return;
      }
      const { error } = await supabase.auth.signOut();
      if (error) throw error;
      log("info", "Signed out (current device)", undefined, "signout");
    } catch (e) {
      log("error", "Sign out failed", e, "signout");
    } finally {
      setLoading(false);
    }
  };

  const callMe = async () => {
    setLoading(true);
    try {
      if (!supabase) {
        log("warn", "Supabase client not initialized", undefined, "GET /me");
        return;
      }
      const current = (await supabase.auth.getSession()).data.session;
      if (!current) {
        log("warn", "No session. Sign in first.", undefined, "GET /me");
        return;
      }
      const res = await fetch(`${gatewayUrl}/me`, {
        headers: {
          Authorization: `Bearer ${current.access_token}`,
        },
      });
      const body = await res.json().catch(() => ({}));
      log("info", `GET /me -> ${res.status}`, body, "GET /me");
    } catch (e) {
      log("error", "GET /me failed", e, "GET /me");
    } finally {
      setLoading(false);
    }
  };

  const copyAccessToken = async () => {
    try {
      if (!supabase) {
        log("warn", "Supabase client not initialized", undefined, "copy-token");
        return;
      }
      const current = (await supabase.auth.getSession()).data.session;
      const token = current?.access_token ?? "";
      await navigator.clipboard.writeText(token);
      log("info", "Access token copied to clipboard", { preview: truncateToken(token) }, "copy-token");
    } catch (e) {
      log("error", "Copy token failed", e, "copy-token");
    }
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-zinc-50 font-sans dark:bg-black">
      <main className="flex min-h-screen w-full max-w-3xl flex-col gap-8 py-12 px-6 sm:px-10 bg-white dark:bg-black">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <Image className="dark:invert" src="/next.svg" alt="Next.js" width={80} height={16} priority />
            <span className="text-sm text-zinc-500">Admin Auth Tester</span>
          </div>
        </div>

        <section className="flex flex-col gap-3">
          <h2 className="text-xl font-semibold text-zinc-900 dark:text-zinc-50">Authentication</h2>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <input
              type="email"
              placeholder="email@example.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 dark:bg-zinc-950 dark:border-zinc-800 dark:text-zinc-100"
            />
            <input
              type="password"
              placeholder="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 dark:bg-zinc-950 dark:border-zinc-800 dark:text-zinc-100"
            />
            <button
              onClick={signInEmailPassword}
              disabled={loading}
              className="rounded-md bg-black text-white dark:bg-white dark:text-black px-3 py-2 text-sm hover:opacity-90 disabled:opacity-50"
            >
              Log in (or Sign up)
            </button>
            <button
              onClick={signInAnonymous}
              disabled={loading}
              className="rounded-md bg-zinc-900 text-white dark:bg-zinc-800 px-3 py-2 text-sm hover:opacity-90 disabled:opacity-50"
            >
              Anonymous sign-in
            </button>
            <button
              onClick={signOut}
              disabled={loading}
              className="rounded-md bg-zinc-200 text-zinc-900 dark:bg-zinc-800 dark:text-zinc-100 px-3 py-2 text-sm hover:opacity-90 disabled:opacity-50"
            >
              Log out
            </button>
            <button
              onClick={copyAccessToken}
              className="rounded-md border border-zinc-300 dark:border-zinc-700 px-3 py-2 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-900"
            >
              Copy access token
            </button>
          </div>
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 pt-2">
            <div className="flex items-center gap-2">
              <label className="text-sm text-zinc-600 dark:text-zinc-400">Gateway URL</label>
            </div>
            <div className="flex gap-2">
              <input
                value={gatewayUrl}
                onChange={(e) => setGatewayUrl(e.target.value)}
                className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 dark:bg-zinc-950 dark:border-zinc-800 dark:text-zinc-100"
              />
              <button
                onClick={callMe}
                disabled={loading}
                className="whitespace-nowrap rounded-md bg-emerald-600 text-white px-3 py-2 text-sm hover:opacity-90 disabled:opacity-50"
              >
                Call /me
              </button>
            </div>
          </div>
        </section>

        <section className="flex flex-col gap-3">
          <h2 className="text-xl font-semibold text-zinc-900 dark:text-zinc-50">Supabase Config</h2>
          <div className="grid grid-cols-1 gap-3">
            <input
              placeholder="NEXT_PUBLIC_SUPABASE_URL"
              value={sbUrl ?? ""}
              onChange={(e) => setSbUrl(e.target.value)}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 dark:bg-zinc-950 dark:border-zinc-800 dark:text-zinc-100"
            />
            <input
              placeholder="NEXT_PUBLIC_SUPABASE_ANON_KEY"
              value={sbKey ?? ""}
              onChange={(e) => setSbKey(e.target.value)}
              className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm text-zinc-900 dark:bg-zinc-950 dark:border-zinc-800 dark:text-zinc-100"
            />
            <div className="flex items-center gap-2">
              <button
                onClick={() => {
                  if (typeof window !== "undefined") {
                    if (sbUrl) window.localStorage.setItem("sb.url", sbUrl);
                    if (sbKey) window.localStorage.setItem("sb.key", sbKey);
                    log("info", "Saved Supabase config to localStorage");
                  }
                }}
                className="rounded-md bg-indigo-600 text-white px-3 py-2 text-sm hover:opacity-90"
              >
                Save Supabase settings
              </button>
              <div className="text-xs text-zinc-500" suppressHydrationWarning>
                Client initialized: {hasMounted ? String(!!supabase) : "…"}
              </div>
            </div>
          </div>
        </section>
        {/* Auth security endpoints */}
        <section className="rounded-lg border border-zinc-800 bg-zinc-950 p-4">
          <h3 className="mb-2 text-sm font-medium text-zinc-200">Security & Sessions</h3>
          <div className="grid gap-2 sm:grid-cols-3">
            <button
              disabled={loading}
              onClick={async () => {
                setLoading(true);
                try {
                  if (!supabase) { log("warn", "Supabase client not initialized", undefined, "GET /me/security/sessions"); return; }
                  const current = (await supabase.auth.getSession()).data.session;
                  if (!current) { log("warn", "No session. Sign in first.", undefined, "GET /me/security/sessions"); return; }
                  const res = await fetch(`${gatewayUrl}/me/security/sessions`, { headers: { Authorization: `Bearer ${current.access_token}` } });
                  const body = await res.json().catch(() => ({}));
                  log("info", `GET /me/security/sessions -> ${res.status}`, body, "GET /me/security/sessions");
                } catch (e) { log("error", "GET /me/security/sessions failed", e, "GET /me/security/sessions"); }
                finally { setLoading(false); }
              }}
              className="rounded-md bg-zinc-800 px-3 py-2 text-xs text-zinc-100 hover:bg-zinc-700 disabled:opacity-50"
            >
              List Sessions
            </button>
            <button
              disabled={loading}
              onClick={async () => {
                setLoading(true);
                try {
                  if (!supabase) { log("warn", "Supabase client not initialized", undefined, "POST /me/security/logout-all"); return; }
                  const current = (await supabase.auth.getSession()).data.session;
                  if (!current) { log("warn", "No session. Sign in first.", undefined, "POST /me/security/logout-all"); return; }
                  const res = await fetch(`${gatewayUrl}/me/security/logout-all`, { method: 'POST', headers: { Authorization: `Bearer ${current.access_token}` } });
                  const body = await res.json().catch(() => ({}));
                  log("info", `POST /me/security/logout-all -> ${res.status}`, body, "POST /me/security/logout-all");
                } catch (e) { log("error", "POST /me/security/logout-all failed", e, "POST /me/security/logout-all"); }
                finally { setLoading(false); }
              }}
              className="rounded-md bg-zinc-800 px-3 py-2 text-xs text-zinc-100 hover:bg-zinc-700 disabled:opacity-50"
            >
              Logout All (soft)
            </button>
            <button
              disabled={loading}
              onClick={async () => {
                setLoading(true);
                try {
                  if (!supabase) { log("warn", "Supabase client not initialized", undefined, "POST /me/security/logout-all-supabase"); return; }
                  const current = (await supabase.auth.getSession()).data.session;
                  if (!current) { log("warn", "No session. Sign in first.", undefined, "POST /me/security/logout-all-supabase"); return; }
                  const res = await fetch(`${gatewayUrl}/me/security/logout-all-supabase`, { method: 'POST', headers: { Authorization: `Bearer ${current.access_token}` } });
                  const body = await res.json().catch(() => ({}));
                  log("info", `POST /me/security/logout-all-supabase -> ${res.status}`, body, "POST /me/security/logout-all-supabase");
                } catch (e) { log("error", "POST /me/security/logout-all-supabase failed", e, "POST /me/security/logout-all-supabase"); }
                finally { setLoading(false); }
              }}
              className="rounded-md bg-zinc-800 px-3 py-2 text-xs text-zinc-100 hover:bg-zinc-700 disabled:opacity-50"
            >
              Logout All (Supabase)
            </button>
          </div>
          <p className="mt-2 text-[10px] text-zinc-500 leading-relaxed">Soft logout revokes tracked sessions in app DB; Supabase global logout invalidates refresh tokens (requires service role key on server).</p>
        </section>

        <section className="flex flex-col gap-2">
          <h3 className="text-lg font-medium text-zinc-900 dark:text-zinc-50">Current user/session</h3>
          <div className="rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-950 p-3 text-sm text-zinc-800 dark:text-zinc-200">
            <div>User ID: {user?.id ?? "<none>"}</div>
            <div>Email: {user?.email ?? "<none>"}</div>
            <div>Anonymous: {String((user as any)?.is_anonymous ?? (user?.app_metadata as any)?.provider === "anon")}</div>
            <div>Access Token: {truncateToken(session?.access_token)}</div>
            <div>Expires At: {session?.expires_at ?? "-"}</div>
          </div>
        </section>

        <section className="flex flex-col gap-2 pb-10">
          <h3 className="text-lg font-medium text-zinc-900 dark:text-zinc-50">Logs</h3>
          <div className="h-64 overflow-auto rounded-md border border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-950 p-2 text-xs">
            {logs.length === 0 ? (
              <div className="text-zinc-500">No logs yet.</div>
            ) : (
              <ul className="space-y-1">
                {logs.map((l, idx) => (
                  <li key={idx} className="flex gap-2">
                    <span className="text-zinc-400">{new Date(l.t).toLocaleTimeString()}</span>
                    {l.ctx ? (
                      <span className="rounded-sm bg-zinc-200 dark:bg-zinc-800 px-1 text-[10px] text-zinc-700 dark:text-zinc-200">
                        {l.ctx}
                      </span>
                    ) : null}
                    <span
                      className={
                        l.level === "error"
                          ? "text-red-600"
                          : l.level === "warn"
                          ? "text-amber-600"
                          : "text-emerald-700"
                      }
                    >
                      {l.level.toUpperCase()}
                    </span>
                    <span className="text-zinc-800 dark:text-zinc-100">{l.msg}</span>
                    {l.data ? (
                      <pre className="ml-auto w-1/2 overflow-auto whitespace-pre-wrap break-words text-zinc-600 dark:text-zinc-300">{JSON.stringify(l.data, null, 2)}</pre>
                    ) : null}
                  </li>
                ))}
              </ul>
            )}
          </div>
        </section>
      </main>
    </div>
  );
}
