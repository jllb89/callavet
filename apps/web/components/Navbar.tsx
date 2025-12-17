"use client";

type NavLinkProps = { href: string; text: string };

function AnimatedLink({ href, text }: NavLinkProps) {
  const chars = Array.from(text);
  const underlineDelay = chars.length * 34 + 240; // ms (slower, slightly longer)
  return (
    <a href={href} className="group relative inline-flex items-center text-white font-light text-[15px] sm:text-base leading-none">
      <span className="relative inline-block">
        {/* Normal text for perfect kerning at rest */}
        <span className="link-normal block">{text}</span>
        {/* Per-character roller overlay, only shown on desktop hover */}
        <span className="link-roller absolute inset-0 inline-flex" aria-hidden>
          {chars.map((ch, i) => (
            <span key={i} className="roller-mask">
              <span
                className="roller-char"
                style={{ transitionDelay: `${i * 34}ms` }}
              >
                {ch === " " ? "\u00A0" : ch}
              </span>
              <span
                className="roller-clone"
                aria-hidden
                style={{ transitionDelay: `${i * 34}ms` }}
              >
                {ch === " " ? "\u00A0" : ch}
              </span>
            </span>
          ))}
        </span>
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
    <div className="absolute left-[24px] right-[24px] sm:left-[100px] sm:right-[100px] top-[24px] sm:top-[60px] flex items-center justify-between opacity-0 animate-[fadeIn_1400ms_ease-out_1200ms_forwards]">
      <a href="/" className="text-white text-xl sm:text-2xl">Call a Vet</a>
      <nav className="hidden sm:flex items-center gap-8 text-white">
        <AnimatedLink href="#how" text="Cómo funciona" />
        <AnimatedLink href="#care" text="Planes de cuidado" />
        <AnimatedLink href="#faq" text="FAQ" />
        <a href="#login" className="ml-2 rounded-[33.5px] bg-white text-black px-6 py-3 text-base">Iniciar sesión</a>
      </nav>
    </div>
  );
}
