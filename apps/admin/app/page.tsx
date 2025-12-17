"use client";

export default function AdminPlaceholder() {
  return (
    <div className="min-h-screen flex items-center justify-center bg-white text-zinc-900 dark:bg-black dark:text-zinc-50 font-sans">
      <div className="max-w-md w-full p-8 text-center">
        <h1 className="text-2xl font-semibold mb-3">Admin Console</h1>
        <p className="text-sm text-zinc-600 dark:text-zinc-300 mb-6">
          Admin UI placeholder. The public landing lives under apps/web.
        </p>
        <div className="flex items-center justify-center gap-3">
          <a href="/" className="rounded-full bg-black text-white dark:bg-white dark:text-black px-5 py-2 text-sm hover:opacity-90">Go to Landing</a>
          <a href="/docs" className="rounded-full border border-zinc-300 dark:border-zinc-700 px-5 py-2 text-sm hover:bg-zinc-50 dark:hover:bg-zinc-900">Docs</a>
        </div>
      </div>
    </div>
  );
}
