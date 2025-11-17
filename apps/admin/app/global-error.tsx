"use client";

// Global error boundary for the admin app. Keeps build from failing due to default fallback issues.
// See: https://nextjs.org/docs/app/building-your-application/routing/error-handling#handling-errors-globally
export default function GlobalError({ error, reset }: { error: Error; reset: () => void }) {
  return (
    <html>
      <body className="min-h-screen bg-black text-zinc-200 flex items-center justify-center p-6">
        <div className="max-w-md space-y-4 text-center">
          <h1 className="text-xl font-semibold">Something went wrong</h1>
          <pre className="rounded-md bg-zinc-900 p-3 text-xs overflow-auto max-h-60 whitespace-pre-wrap break-all">
            {error?.message || String(error)}
          </pre>
          <button
            onClick={() => reset()}
            className="rounded bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-500"
          >
            Try again
          </button>
        </div>
      </body>
    </html>
  );
}
