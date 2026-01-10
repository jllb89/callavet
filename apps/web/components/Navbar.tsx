"use client";

import Image from "next/image";
import { useEffect, useState } from "react";

const navFont = "font-abc";

export default function Navbar() {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const handleScroll = () => setScrolled(window.scrollY > 8);
    handleScroll();
    window.addEventListener("scroll", handleScroll, { passive: true });
    return () => window.removeEventListener("scroll", handleScroll);
  }, []);

  const segmentBase = "flex h-[56px] items-center gap-3 sm:gap-4 rounded-xl border transition-[background,backdrop-filter,border-color] duration-300";
  const segmentIdle = "border-transparent bg-transparent";
  const segmentScrolled = "bg-black/25 backdrop-blur-[18px] border-white/0";

  const primaryLinks = [
    { href: "#como-funciona", label: "Nuestra plataforma" },
    { href: "#nuestro-equipo", label: "Compañía" },
  ];

  return (
    <div className={`fixed left-0 right-0 top-[20px] z-40 flex justify-center px-0 sm:px-1 ${navFont}`}>
      <div className="flex w-full max-w-[2000px] items-center justify-between gap-1 sm:gap-2">
        <div className={`${segmentBase} ${scrolled ? segmentScrolled : segmentIdle} px-3 sm:px-3`}> 
          <div className="flex items-center gap-2 sm:gap-3">
            <a href="/" className="flex items-center mr-4 sm:mr-8">
              <Image src="/logo-navbar.svg" alt="Call a Vet" width={40} height={40} className="h-30 w-30" priority />
            </a>
            <nav className="hidden md:flex items-center gap-8">
              {primaryLinks.map((item) => (
                <a
                  key={item.label}
                  href={item.href}
                  className="group relative max-w-4xl text-md font-light inline-flex items-center gap-1"
                >
                  <span className="relative inline-block">
                    <span>{item.label}</span>
                    <span className="nav-underline" />
                  </span>
                  <CaretIcon />
                </a>
              ))}
            </nav>
          </div>
        </div>

        <div className="flex items-center gap-2 sm:gap-3 font-abc-light text-[17px] leading-[1.6] pr-3 sm:pr-2 md:pr-3">
          <a
            href="#login"
            className="inline-flex items-center rounded-[33.5px] bg-white px-6 py-[10px] text-sm font-normal text-black transition-colors hover:bg-white/90"
          >
            Iniciar sesión
          </a>
        </div>
      </div>
    </div>
  );
}

function CaretIcon() {
  return (
    <svg
      className="h-4 w-4 text-white/60 transition-colors group-hover:text-white/80"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
    >
      <path d="M7 9l5 5 5-5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
