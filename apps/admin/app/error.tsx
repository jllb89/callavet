"use client";

export default function Error({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <div className="min-h-[60vh] flex items-center justify-center p-6">
      <div className="max-w-md space-y-4 text-center">
        <h1 className="text-xl font-semibold text-zinc-100">Something went wrong</h1>
        <pre className="rounded-md bg-zinc-900 p-3 text-xs text-zinc-300 overflow-auto max-h-60 whitespace-pre-wrap break-all">
          {error?.message || String(error)}
        </pre>
        <button
          onClick={() => reset()}
          className="rounded bg-emerald-600 px-4 py-2 text-sm font-medium text-white hover:bg-emerald-500"
        >
          Try again
        </button>
      </div>
    </div>
  );
}
