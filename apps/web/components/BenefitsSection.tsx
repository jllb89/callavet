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
        title: "Red de veterinarios aliados cuando sí se necesita presencia física",
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
            <div className="mx-auto w-full max-w-[1600px] h-[60vh] min-h-[65vh] rounded-2xl border border-white/5 bg-black/30 p-6 sm:p-8 md:p-10">
                <div className="grid w-full h-full gap-8 md:grid-cols-5 items-stretch">
                        <div className="md:col-span-2 flex h-full flex-col gap-2 text-white font-abc">
                        <div className="flex flex-col gap-2">
                            <Image src="/logo-navbar.svg" alt="Call a Vet" width={28} height={28} className="h-25 w-25" />
                            <div className="text-4xl font-light leading-tight">
                                Más control, menos urgencias, mejores decisiones veterinarias.
                            </div>
                        </div>
                        <div className="text-lg font-light leading-7 text-white/90">
                            Una plataforma diseñada para resolver rápido y cuidar mejor, ahorrando en costos innecesarios.
                        </div>

                        <a
                            href="#assist"
                            className="mt-3 self-start inline-flex items-center justify-center rounded-[33.5px] bg-white px-4 py-2 text-sm font-light text-black transition-colors hover:bg-white/60"
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
                                        className={`w-full text-left py-2.5 sm:py-3.5 transition-colors duration-500 ${isActive ? "bg-white/0" : "bg-white/0"}`}
                                    >
                                        <div className={`text-base sm:text-lg leading-7 font-light transition-colors duration-300 ${isActive ? "text-white" : "text-white/10 hover:text-white/35"}`}>
                                            {item.title}
                                        </div>
                                        {isActive && (
                                            <p className="mt-2 text-sm font-light leading-6 text-white/80 animate-[benefitFade_320ms_ease-out]">
                                                {item.description}
                                            </p>
                                        )}
                                        {isActive && (
                                            <div className="relative mt-3 h-px overflow-hidden bg-white/15 animate-[benefitFade_320ms_ease-out]">
                                                <div
                                                    key={activeIndex}
                                                    className="absolute inset-y-0 left-0 bg-white animate-[benefitProgress_linear]"
                                                    style={{ animationDuration: `${CYCLE_MS}ms` }}
                                                />
                                            </div>
                                        )}
                                    </button>
                                );
                            })}
                        </div>
                    </div>

                    <div className="md:col-span-3 w-full h-full flex min-h-0">
                        <div className="relative w-full h-full min-h-[320px] md:min-h-[420px] overflow-hidden rounded-lg bg-gradient-to-br from-white/10 via-white/5 to-white/10">
                            <Image
                                src="/bg-1.jpg"
                                alt="Caballo en atención veterinaria"
                                fill
                                className="object-cover opacity-90"
                                sizes="(min-width: 768px) 60vw, 100vw"
                                priority
                            />
                            <div className="absolute inset-0 bg-gradient-to-l from-black via-black/30 to-transparent" />
                        </div>
                    </div>
                </div>
            </div>

            <style jsx>{`
        @keyframes benefitProgress {
          from { width: 0%; }
          to { width: 100%; }
        }
        @keyframes benefitFade {
          from { opacity: 0; transform: translateY(6px); }
          to { opacity: 1; transform: translateY(0); }
        }
      `}</style>
        </section>
    );
}
