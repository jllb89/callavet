"use client";

type NavLinkProps = { href: string; text: string };

function AnimatedLink({ href, text }: NavLinkProps) {
  const chars = Array.from(text);
  const underlineDelay = chars.length * 24 + 180; // ms
  return (
    <a href={href} className="group relative inline-flex items-center text-white">
      <span className="inline-flex">
        {chars.map((ch, i) => (
          <span key={i} className="roller-mask">
            <span
              className="roller-char"
              style={{ transitionDelay: `${i * 24}ms` }}
            >
              {ch === " " ? "\u00A0" : ch}
            </span>
            <span
              className="roller-clone"
              aria-hidden
              style={{ transitionDelay: `${i * 24}ms` }}
            >
              {ch === " " ? "\u00A0" : ch}
            </span>
          </span>
        ))}
      </span>
      <span
        className="nav-underline"
        style={{ transitionDelay: `${underlineDelay}ms` }}
      />
    </a>
  );
}

export default function Navbar() {
  return (
    <div className="absolute left-[24px] right-[24px] sm:left-[100px] sm:right-[100px] top-[24px] sm:top-[60px] flex items-center justify-between opacity-0 animate-[fadeIn_700ms_ease-out_400ms_forwards]">
      <a href="/" className="text-white text-xl sm:text-2xl">Call a Vet</a>
      <nav className="hidden sm:flex items-center gap-8 text-white text-sm">
        <AnimatedLink href="#how" text="Cómo funciona" />
        <AnimatedLink href="#care" text="Planes de cuidado" />
        <AnimatedLink href="#faq" text="FAQ" />
        <a href="#login" className="ml-2 rounded-[33.5px] bg-white text-black px-6 py-3 text-base">Iniciar sesión</a>
      </nav>
    </div>
  );
}
