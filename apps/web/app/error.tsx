"use client";
export default function ErrorPage({ error }: { error: Error & { digest?: string } }){
  return <div style={{padding:'2rem'}}><h1>Something went wrong</h1><pre style={{whiteSpace:'pre-wrap'}}>{error.message}</pre></div>;
}
