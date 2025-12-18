import Image from "next/image";
import Navbar from "../components/Navbar";
import ScrollEffects from "../components/ScrollEffects";

export default function Home() {
  return (
    <div className="min-h-screen bg-white text-zinc-900">
      {/* Header/Hero (Figma-based) */}
      <header id="hero" className="relative w-full min-h-[800px] sm:min-h-screen">
        {/* Back background (static, attached, width-based) */}
        <img
          src="/bg-2.png"
          alt="Background back"
          className="fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-screen h-auto object-contain object-center z-0 pointer-events-none"
          aria-hidden
        />
        {/* Front background (shrinks from center with scroll) */}
        <div className="hero-bg fixed inset-0 z-10 pointer-events-none">
          <div className="relative w-full h-full">
            <Image src="/bg-1.jpg" alt="Background front" fill priority className="object-cover object-center" />
          </div>
        </div>
        {/* Overlay gradient for readability across both */}
        <div className="fixed inset-0 z-20 bg-black/30 pointer-events-none" />

        {/* Top nav */}
        <Navbar />

        {/* Hero content near bottom */}
        <div className="hero-content fixed left-0 right-0 bottom-[5vh] sm:bottom-[12vh] z-30 flex flex-col items-center px-6 animate-[riseIn_900ms_ease-out_120ms_forwards]">
          <h1 className="text-white text-4xl sm:text-5xl font-normal mb-2">Call a Vet</h1>
          <p className="text-white text-xl sm:text-2xl text-center max-w-3xl mb-8 font-light">
            Atención veterinaria especializada en minutos para tu caballo.
          </p>
          <p className="text-white text-base sm:text-xl text-center max-w-3xl mb-10 font-light">
            Describe el caso, nuestro asistente inteligente te guía con preguntas y te conectamos con un veterinario verificado.
          </p>
          <div className="flex items-center justify-center gap-3">
            <a href="#assist" className="rounded-[33.5px] bg-white text-black px-8 py-3 text-base hover:bg-[#dddddd] transition-colors duration-200">Obtener asistencia ahora</a>
            <a href="#plans" className="rounded-[33.5px] bg-black text-white px-8 py-3 text-base hover:bg-[#dddddd] transition-colors duration-200">Ver planes</a>
          </div>
        </div>
      </header>
      {/* Scroll effects driver */}
      <ScrollEffects />

      {/* How section */}
      <section id="how" className="h-screen">
          <h2 className="how-title fixed top-1/2 left-1/2 how-center z-40 text-white text-4xl sm:text-4xl font-light">¿Cómo funciona?</h2>
          {/* Marquee under bg-1 and hero, over bg-2 */}
          <div className="marquee marquee--30 z-[5]" aria-hidden>
            <div className="marquee-track text-white font-light text-[8vw]">
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
            </div>
          </div>
          {/* Second marquee at 60vh, reverse direction */}
          <div className="marquee marquee--60 z-[5]" aria-hidden>
            <div className="marquee-track marquee-track--rtl text-white font-light text-[8vw]">
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
              <span className="marquee-item">Sin filas. Soporte 24/7. Cancela cuando quieras. Atención personalizada para tu caballo.</span>
            </div>
          </div>
      </section>

      {/* Features (placeholder) */}
      <section id="features" className="mx-auto max-w-6xl px-6 sm:px-10 py-24">
        <h2 id="features-intro" className="text-3xl font-semibold mb-8">Why Call a Vet</h2>
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
