"use client";

import { useEffect } from "react";

export default function ScrollEffects() {
  useEffect(() => {
    const hero = document.getElementById("hero");
    const features = document.getElementById("features");
    const reveal = document.getElementById("features-intro");
    const how = document.getElementById("how");

    const clamp = (v: number, min = 0, max = 1) => Math.min(Math.max(v, min), max);

    const onScroll = (scrollY: number) => {
      const heroH = hero?.offsetHeight || window.innerHeight;
      const progress = clamp(scrollY / heroH);
      // Fade hero content faster (gone by ~35-40% of hero height)
      const heroOpacity = clamp(1 - progress * 2.6, 0, 1);
      document.documentElement.style.setProperty("--hero-opacity", heroOpacity.toFixed(3));
      // Two-phase background: phase 1 scale, phase 2 translate up while keeping scale
      const phase1End = 0.65; // portion of hero height used to scale
      const minScale = 0.35;
      const p1 = clamp(progress / phase1End);
      const bgScale = progress <= phase1End
        ? 1 - (1 - minScale) * p1
        : minScale;
      document.documentElement.style.setProperty("--hero-bg-scale", bgScale.toFixed(3));

      // Keep scaling visually centered by adding a small downward offset during scale
      const centerOffset = (1 - bgScale) * 100; // vh, keep scale anchored to viewport center

      const phase2Start = phase1End;
      const phase2Span = 0.4; // span of hero height used to translate out
      const p2 = clamp((progress - phase2Start) / phase2Span);
      const translateY = centerOffset - p2 * 80; // start slightly down, then move up
      document.documentElement.style.setProperty("--hero-bg-ty", `${translateY}vh`);
      // Fade/scale/slide the title: first fade+scale, then slide up after fully visible
      const delayStart = 0.45; // start after ~45% of hero scroll
      const ramp = 0.15;       // reach full over the next ~15%
      // Fade in
      let howOpacity = clamp((progress - delayStart) / ramp, 0, 1);
      const howScale = 1.02 - howOpacity * 0.02;

      // After fully visible, slide up toward top; use same element via translate
      const slideStart = delayStart + ramp; // when opacity is 1
      const slideSpan = 0.3;
      const slideP = clamp((progress - slideStart) / slideSpan, 0, 1);
      const howTy = -slideP * 40; // move up to -40vh equivalent

      // Fade out after some scrolling; reversible on scroll up
      const fadeOutStart = slideStart + 0.2;
      const fadeOutSpan = .2; // even longer, slower fade
      const fadeOutP = clamp((progress - fadeOutStart) / fadeOutSpan, 0, 1);
      const fadeOutFactor = 1 - fadeOutP; // linear to avoid end acceleration
      howOpacity = Math.max(0, howOpacity * fadeOutFactor);
      // Secondary fade is driven by absolute scroll distance, after we've cleared the hero + bg
      // Start after ~105% of hero height, ramp over another ~25% for a gentle ease
      const whiteGateStart = heroH * 1.05;
      const whiteGateSpan = heroH * 0.25;
      const whiteGateP = clamp((scrollY - whiteGateStart) / whiteGateSpan, 0, 1);
      // smoothstep for softer entry
      const how2Opacity = whiteGateP * whiteGateP * (3 - 2 * whiteGateP);
      const marqueeOpacity = fadeOutFactor; // sync marquee fade with primary title fade-out window
      const bg2Opacity = fadeOutFactor; // fade back background with marquee/title
      const overlayOpacity = fadeOutFactor; // fade dark overlay so background goes fully white

      document.documentElement.style.setProperty("--how-opacity", howOpacity.toFixed(3));
      document.documentElement.style.setProperty("--how2-opacity", how2Opacity.toFixed(3));
      document.documentElement.style.setProperty("--how-scale", howScale.toFixed(3));
      document.documentElement.style.setProperty("--how-ty", `${howTy}vh`);
      document.documentElement.style.setProperty("--marquee-opacity", marqueeOpacity.toFixed(3));
      document.documentElement.style.setProperty("--bg2-opacity", bg2Opacity.toFixed(3));
      document.documentElement.style.setProperty("--overlay-opacity", overlayOpacity.toFixed(3));

      // No snap/lock; natural scroll continues
    };

    const lenis: any = (window as any).lenis;
    if (lenis && typeof lenis.on === "function") {
      // Initialize once in case we mount mid-scroll
      onScroll(lenis.scroll || 0);
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
