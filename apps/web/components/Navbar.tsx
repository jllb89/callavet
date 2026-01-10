"use client";

import Image from "next/image";
import { useEffect, useState } from "react";

const navFont = "font-abc";

export default function Navbar() {
  const [scrolled, setScrolled] = useState(false);
  const [theme, setTheme] = useState<"dark" | "light">("dark");

  useEffect(() => {
    const handleScroll = () => setScrolled(window.scrollY > 8);
    handleScroll();
    window.addEventListener("scroll", handleScroll, { passive: true });
    return () => window.removeEventListener("scroll", handleScroll);
  }, []);

  useEffect(() => {
    const stored = localStorage.getItem("theme");
    const preferred = stored === "light" ? "light" : "dark";
    setTheme(preferred);
    document.documentElement.classList.toggle("theme-light", preferred === "light");
  }, []);

  useEffect(() => {
    document.documentElement.classList.toggle("theme-light", theme === "light");
    localStorage.setItem("theme", theme);
  }, [theme]);

  const toggleTheme = () => setTheme((prev) => (prev === "light" ? "dark" : "light"));

  const segmentBase = "flex h-[56px] items-center gap-3 sm:gap-4 rounded-xl border transition-[background,backdrop-filter,border-color] duration-300";
  const segmentIdle = "border-transparent bg-transparent";
  const segmentScrolled = "bg-[color:var(--nav-scrim)] backdrop-blur-[18px] border-[color:var(--nav-scrim-border)]";

  const primaryLinks = [
    { href: "#como-funciona", label: "Nuestra plataforma" },
    { href: "#nuestro-equipo", label: "Compañía" },
  ];

  return (
    <div className={`fixed left-0 right-0 top-[20px] z-40 flex justify-center px-0 sm:px-1 text-white ${navFont}`}>
      <div className="flex w-full max-w-[2000px] items-center justify-between gap-1 sm:gap-2">
        <div className={`${segmentBase} ${scrolled ? segmentScrolled : segmentIdle} px-3 sm:px-3`}> 
          <div className="flex items-center gap-2 sm:gap-3">
            <a href="/" className="flex items-center mr-4 sm:mr-8 text-white">
              <Image src="/logo-navbar.svg" alt="Call a Vet" width={40} height={40} className="h-30 w-30" priority />
            </a>
            <nav className="hidden md:flex items-center gap-8">
              {primaryLinks.map((item) => (
                <a
                  key={item.label}
                  href={item.href}
                  className="group relative max-w-4xl text-md font-light inline-flex items-center gap-1 text-white"
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

        <div className={`${segmentBase} ${scrolled ? segmentScrolled : segmentIdle} px-3 sm:px-3`}>
          <div className="flex items-center gap-2 sm:gap-3 font-abc-light text-[17px] leading-[1.6] pr-0 sm:pr-0 md:pr-0">
            <button
              aria-label="Cambiar tema"
              onClick={toggleTheme}
              className="inline-flex h-[40px] w-[40px] items-center justify-center rounded-full border border-white/20 bg-white/5 text-white transition-colors hover:bg-white/10"
            >
              {theme === "light" ? <MoonIcon /> : <SunIcon />}
            </button>
            <a
              href="#login"
              className="btn-login inline-flex items-center rounded-[33.5px] px-6 py-[10px] text-sm font-normal transition-colors"
            >
              Iniciar sesión
            </a>
          </div>
        </div>
      </div>
    </div>
  );
}

function SunIcon() {
  return (
    <svg
      className="h-4 w-4"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2m0 16v2m10-10h-2M4 12H2m15.364-7.364-1.414 1.414M8.05 15.95l-1.414 1.414m0-10.607 1.414 1.414m10.607 10.607-1.414-1.414" />
    </svg>
  );
}

function MoonIcon() {
  return (
    <svg
      className="h-4 w-4"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79Z" />
    </svg>
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
