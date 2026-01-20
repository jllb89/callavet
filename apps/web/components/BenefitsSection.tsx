"use client";

import Image from "next/image";
import { useEffect, useState } from "react";

const benefits = [
    {
        title: "Resuelve en minutos, no en días",
        description: "Decisiones rápidas con respaldo veterinario, sin mover al caballo",
    },
    {
        title: "Chat o video: tú eliges cómo atender cada caso",
        description: "La atención adecuada según la gravedad del problema",
    },
    {
        title: "Planes de cuidado propuestos (incluidos, sin costo extra)",
        description: "No solo resuelvas el problema de hoy: prevé el de mañana",
    },
    {
        title: "Historial clínico y seguimiento continuo",
        description: "Toda la información del caballo, siempre a la mano",
    },
    {
        title: "Red de veterinarios aliados cuando se requiera de presencia física",
        description: "La visita física correcta, en el momento correcto",
    },
];

const CYCLE_MS = 11000;

export default function BenefitsSection() {
    const [activeIndex, setActiveIndex] = useState(0);

    useEffect(() => {
        const id = setTimeout(() => {
            setActiveIndex((prev) => (prev + 1) % benefits.length);
        }, CYCLE_MS);

        return () => clearTimeout(id);
    }, [activeIndex]);

    return (
        <section id="beneficios" className="w-full px-6">
            <div className="mx-auto w-full max-w-[1600px] h-auto min-h-[520px] sm:min-h-[560px] lg:min-h-[620px] xl:min-h-[65vh] rounded-2xl border border-[color:var(--border)] bg-[color:var(--benefits-bg)] p-6 sm:p-8 md:p-10">
                <div className="grid w-full h-full gap-8 lg:grid-cols-5 items-stretch">
                    <div className="lg:col-span-2 flex h-full flex-col gap-2 text-[color:var(--text)] font-abc">
                        <div className="flex flex-col gap-2">
                            <Image src="/logo-navbar.svg" alt="Call a Vet" width={28} height={28} className="h-25 w-25 icon-dark" />
                            <Image src="/lightmode/logo-navbar 1.svg" alt="Call a Vet" width={28} height={28} className="h-25 w-25 icon-light" />
                            <div className="text-3xl sm:text-3xl lg:text-3xl xl:text-3xl font-light leading-tight">
                                Más control, menos urgencias, mejores decisiones veterinarias.
                            </div>
                        </div>
                        <div className="text-base sm:text-lg lg:text-xl xl:text-xl font-light leading-7 text-[color:var(--text)]">
                            Una plataforma diseñada para resolver rápido y cuidar mejor, ahorrando en costos innecesarios.
                        </div>

                        <a
                            href="#assist"
                            className="mt-3 self-start inline-flex items-center justify-center rounded-[33.5px] bg-[color:var(--text)] px-4 sm:px-5 lg:px-5 py-2 sm:py-2.5 text-sm sm:text-base font-light text-[color:var(--bg)] transition-colors hover:bg-[color:var(--text)]/85"
                        >
                            Empezar ahora
                        </a>

                        <div className="flex-1" />

                        <div className="flex flex-col overflow-hidden mt-4 sm:mt-5">
                            {benefits.map((item, index) => {
                                const isActive = index === activeIndex;
                                return (
                                    <button
                                        key={item.title}
                                        onClick={() => setActiveIndex(index)}
                                        className="w-full text-left py-2.5 sm:py-3 lg:py-3 transition-colors duration-500"
                                    >
                                        <div className={`text-base sm:text-lg md:text-lg lg:text-xl leading-7 font-light transition-colors duration-300 ${isActive ? "text-[color:var(--text)]" : "text-[color:var(--benefits-title-inactive)] hover:text-[color:var(--benefits-title-hover)]"}`}>
                                            {item.title}
                                        </div>
                                        {isActive && (
                                            <p className="mt-2 text-xs sm:text-xs md:text-xs lg:text-base font-light leading-6 text-[color:var(--muted)] animate-[benefitFade_320ms_ease-out]">
                                                {item.description}
                                            </p>
                                        )}
                                        {isActive && (
                                            <div className="relative mt-3 h-px overflow-hidden bg-[color:var(--border)] animate-[benefitFade_320ms_ease-out]">
                                                <div
                                                    key={activeIndex}
                                                    className="absolute inset-y-0 left-0 bg-[color:var(--text)] animate-[benefitProgress_linear]"
                                                    style={{ animationDuration: `${CYCLE_MS}ms` }}
                                                />
                                            </div>
                                        )}
                                    </button>
                                );
                            })}
                        </div>
                    </div>

                        <div className="lg:col-span-3 w-full flex min-h-0 items-stretch">
                            <div className="relative w-full h-full min-h-[320px] sm:min-h-[360px] lg:min-h-[420px] overflow-hidden rounded-lg bg-[color:var(--benefits-bg)]">
                            <Image
                                src="/bg-1.jpg"
                                alt="Caballo en atención veterinaria"
                                fill
                                className="object-cover opacity-90"
                                sizes="(min-width: 1536px) 50vw, (min-width: 1280px) 55vw, (min-width: 1024px) 60vw, (min-width: 768px) 70vw, 100vw"
                                priority
                            />
                                <div className="absolute inset-0 benefits-overlay-dark" />
                                <div className="absolute inset-0 benefits-overlay-light" />
                        </div>
                    </div>
                </div>
            </div>

        </section>
    );
}
