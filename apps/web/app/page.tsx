import Image from "next/image";
import Navbar from "../components/Navbar";

export default function Home() {
  return (
    <div className="min-h-screen bg-white text-zinc-900 dark:bg-black dark:text-zinc-50">
      {/* Header/Hero (Figma-based) */}
      <header className="relative w-full min-h-[800px] sm:min-h-screen">
        {/* Background image */}
        <Image src="/bg-1.jpg" alt="Background" fill priority className="object-cover" />
        {/* Overlay gradient for readability */}
        <div className="absolute inset-0 bg-black/30" />

        {/* Top nav */}
        <Navbar />

        {/* Hero content near bottom */}
        <div className="absolute left-0 right-0 bottom-[5vh] sm:bottom-[12vh] flex flex-col items-center px-6 opacity-0 animate-[fadeIn_1100ms_ease-out_100ms_forwards]">
          <h1 className="text-white text-4xl sm:text-5xl font-normal mb-2">Call a Vet</h1>
          <p className="text-white text-xl sm:text-2xl text-center max-w-3xl mb-8 font-light">
            Atención veterinaria especializada en minutos para tu caballo.
          </p>
          <p className="text-white text-base sm:text-xl text-center max-w-3xl mb-10 font-light">
            Describe el caso, nuestro asistente inteligente te guía con preguntas y te conectamos con un veterinario verificado.
          </p>
          <div className="flex items-center justify-center gap-3">
            <a href="#assist" className="rounded-[33.5px] bg-white text-black px-8 py-3 text-base">Obtener asistencia ahora</a>
            <a href="#plans" className="rounded-[33.5px] bg-black text-white px-8 py-3 text-base">Ver planes</a>
          </div>
        </div>
      </header>

      {/* Features (placeholder) */}
      <section id="features" className="mx-auto max-w-6xl px-6 sm:px-10 py-24">
        <h2 className="text-3xl font-semibold mb-8">Why Call a Vet</h2>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          <Feature title="Instant Booking" desc="Real-time availability and one-click reservations." />
          <Feature title="Specialty Matching" desc="Match by vet specialty for the right expertise." />
          <Feature title="Secure Records" desc="Session notes and care plans securely stored." />
        </div>
      </section>

      {/* Pricing (placeholder) */}
      <section id="pricing" className="mx-auto max-w-6xl px-6 sm:px-10 py-24">
        <h2 className="text-3xl font-semibold mb-8">Simple Pricing</h2>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
          <Card title="Free" price="$0" desc="Browse KB, prep for consults." cta="Get Started" />
          <Card title="Chat" price="$19" desc="Single chat consult." cta="Book Chat" />
          <Card title="Video" price="$39" desc="Video consult with a vet." cta="Book Video" />
        </div>
      </section>

      {/* Footer */}
      <footer className="mx-auto max-w-6xl px-6 sm:px-10 py-12 border-t border-zinc-200 dark:border-zinc-800 flex items-center justify-between">
        <span className="text-sm text-zinc-500">© {new Date().getFullYear()} Call a Vet</span>
        <nav className="flex items-center gap-4 text-sm">
          <a href="#features" className="hover:underline">Features</a>
          <a href="#pricing" className="hover:underline">Pricing</a>
          <a href="/docs" className="hover:underline">Docs</a>
        </nav>
      </footer>
    </div>
  );
}

function Feature({ title, desc }: { title: string; desc: string }) {
  return (
    <div className="rounded-xl border border-zinc-200 dark:border-zinc-800 p-5">
      <div className="text-lg font-medium mb-2">{title}</div>
      <p className="text-sm text-zinc-600 dark:text-zinc-300">{desc}</p>
    </div>
  );
}

function Card({ title, price, desc, cta }: { title: string; price: string; desc: string; cta: string }) {
  return (
    <div className="rounded-xl border border-zinc-200 dark:border-zinc-800 p-6 flex flex-col gap-3">
      <div className="text-lg font-medium">{title}</div>
      <div className="text-3xl font-semibold">{price}</div>
      <p className="text-sm text-zinc-600 dark:text-zinc-300">{desc}</p>
      <button className="mt-auto rounded-full bg-black text-white dark:bg-white dark:text-black px-5 py-2 text-sm hover:opacity-90">{cta}</button>
    </div>
  );
}
