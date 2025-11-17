export default function NotFound() {
  return (
    <html>
      <body className="min-h-screen bg-black text-zinc-200 flex items-center justify-center p-6">
        <div className="text-center space-y-2">
          <h1 className="text-xl font-semibold">404 — Not found</h1>
          <p className="text-sm text-zinc-400">The requested page could not be found.</p>
          <a href="/" className="inline-block rounded bg-emerald-600 px-3 py-1.5 text-sm text-white hover:bg-emerald-500">Go home</a>
        </div>
      </body>
    </html>
  );
}
