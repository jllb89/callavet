"use client";

import { useEffect } from "react";

export default function ScrollEffects() {
  useEffect(() => {
    const hero = document.getElementById("hero");
    const features = document.getElementById("features");
    const reveal = document.getElementById("features-intro");

    const clamp = (v: number, min = 0, max = 1) => Math.min(Math.max(v, min), max);

    const onScroll = (scrollY: number) => {
      const heroH = hero?.offsetHeight || window.innerHeight;
      const progress = clamp(scrollY / heroH);
      // Fade hero content faster (gone by ~35-40% of hero height)
      const heroOpacity = clamp(1 - progress * 2.6, 0, 1);
      document.documentElement.style.setProperty("--hero-opacity", heroOpacity.toFixed(3));
      // Shrink background more aggressively, centered
      const bgScale = clamp(1 - progress * 0.8, 0.4, 1); // down to ~0.4
      document.documentElement.style.setProperty("--hero-bg-scale", bgScale.toFixed(3));
      // Fade in "¿Cómo funciona?" after a short delay once hero is gone
      const delayStart = 0.45; // start after ~45% of hero scroll
      const ramp = 0.15;       // reach full over the next ~15%
      const howOpacity = clamp((progress - delayStart) / ramp, 0, 1);
      document.documentElement.style.setProperty("--how-opacity", howOpacity.toFixed(3));
      // Subtle scale-in from 1.02 -> 1.0 as it appears
      const howScale = 1.02 - howOpacity * 0.02;
      document.documentElement.style.setProperty("--how-scale", howScale.toFixed(3));
    };

    const lenis: any = (window as any).lenis;
    if (lenis && typeof lenis.on === "function") {
      lenis.on("scroll", (e: any) => onScroll(e.scroll));
    } else {
      let rafId = 0;
      const raf = () => {
        onScroll(window.scrollY || 0);
        rafId = requestAnimationFrame(raf);
      };
      rafId = requestAnimationFrame(raf);
      return () => cancelAnimationFrame(rafId);
    }

    // Reveal intro text when features section is ~40% visible
    if (features && reveal) {
      const io = new IntersectionObserver(
        (entries) => {
          const e = entries[0];
          if (e.isIntersecting) reveal.classList.add("show");
          else reveal.classList.remove("show");
        },
        { threshold: 0.4 }
      );
      io.observe(features);
    }

    return () => {};
  }, []);

  return null;
}
