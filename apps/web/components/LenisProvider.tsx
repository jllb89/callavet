"use client";

import { useEffect } from "react";
import Lenis from "@studio-freight/lenis";

export default function LenisProvider({ children }: { children: React.ReactNode }) {
  useEffect(() => {
    const lenis = new Lenis({
      duration: 4, // slower overall
      easing: (t: number) => 1 - Math.pow(1 - t, 2.2), // slightly softer ease
      smoothWheel: true,
      lerp: 0.04, // gentler interpolation
    });

    // Expose lenis instance for scroll-driven effects
    (window as any).lenis = lenis;

    let rafId: number;
    const raf = (time: number) => {
      lenis.raf(time);
      rafId = requestAnimationFrame(raf);
    };
    rafId = requestAnimationFrame(raf);

    // Respect prefers-reduced-motion
    const media = window.matchMedia("(prefers-reduced-motion: reduce)");
    const updateReduceMotion = () => {
      if (media.matches) lenis.stop();
      else lenis.start();
    };
    updateReduceMotion();
    media.addEventListener("change", updateReduceMotion);

    return () => {
      cancelAnimationFrame(rafId);
      media.removeEventListener("change", updateReduceMotion);
      try { delete (window as any).lenis; } catch {}
      lenis.destroy();
    };
  }, []);

  return children as React.ReactNode;
}
