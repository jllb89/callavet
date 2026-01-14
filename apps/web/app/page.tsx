"use client";

import Image from "next/image";
import { useEffect, useMemo, useRef, useState } from "react";
import Navbar from "../components/Navbar";
import BenefitsSection from "../components/BenefitsSection";
import SavingsCalculator from "../components/SavingsCalculator";

export default function Home() {
  const [billingCycle, setBillingCycle] = useState<"monthly" | "annual">("monthly");
  const [isFading, setIsFading] = useState(false);
  const monthlyRef = useRef<HTMLButtonElement>(null);
  const annualRef = useRef<HTMLButtonElement>(null);
  const [thumbStyle, setThumbStyle] = useState<{ width: number; left: number }>({ width: 0, left: 0 });

  const priceTable = useMemo(
    () => ({
      starter: { monthly: "$999 al mes", annual: "$899 al mes (facturación anual)" },
      plus: { monthly: "$1,899 al mes", annual: "$1,699 al mes (facturación anual)" },
      cuadra5: { monthly: "$2,499 al mes", annual: "$2,299 al mes (facturación anual)" },
      cuadra15: { monthly: "$3,499 al mes", annual: "$3,099 al mes (facturación anual)" },
      proEntrenador: { monthly: "$2,499 al mes", annual: "$2,299 al mes (facturación anual)" },
      ranchoTrabajo: { monthly: "$4,999 al mes", annual: "$4,499 al mes (facturación anual)" },
    }),
    []
  );

  const getPrice = (plan: keyof typeof priceTable) => priceTable[plan][billingCycle];

  const handleBillingChange = (cycle: "monthly" | "annual") => {
    if (cycle === billingCycle || isFading) return;
    setIsFading(true);
    setTimeout(() => {
      setBillingCycle(cycle);
      setIsFading(false);
    }, 160);
  };

  useEffect(() => {
    const computeThumb = () => {
      const monthlyWidth = monthlyRef.current?.offsetWidth ?? 0;
      const annualWidth = annualRef.current?.offsetWidth ?? 0;
      const padding = 4;
      const activeWidth = billingCycle === "monthly" ? monthlyWidth : annualWidth;
      const left = billingCycle === "monthly" ? padding : padding + monthlyWidth;
      setThumbStyle({ width: activeWidth, left });
    };

    computeThumb();
    window.addEventListener("resize", computeThumb);
    return () => window.removeEventListener("resize", computeThumb);
  }, [billingCycle]);

  return (
    <div className="min-h-screen bg-[color:var(--bg)] text-[color:var(--text)]">
      <header className="relative h-[1117px] w-screen overflow-hidden">
        <Image
          src="/bg-1.jpg"
          alt="Background"
          fill
          priority
          className="object-cover"
          sizes="100vw"
        />
        <div className="pointer-events-none absolute bottom-0 left-0 right-0 h-[var(--hero-overlay-height)] bg-gradient-to-b from-[color:var(--hero-grad-from)] via-[color:var(--hero-grad-via)] to-[color:var(--hero-grad-to)]" />

        <Navbar />

        <div className="absolute inset-0 flex flex-col items-center justify-end pb-[96px] px-6 text-center space-y-4">
          <div className="text-4xl font-light">Call a Vet</div>
          <p className="max-w-4xl text-2xl font-light">
            Plataforma de atención veterinaria especializada para tu caballo en minutos.
          </p>
          <p className="max-w-4xl text-md font-light text-[color:var(--text)]">
            Describe el caso, nuestro asistente inteligente te guía con preguntas y te conectamos con un veterinario verificado.
            <br />
            Para dueños de caballos en México.
          </p>
          <div className="flex items-center gap-4 pt-10">
            <a
              href="#assist"
              className="inline-flex items-center justify-center rounded-[33.5px] bg-[color:var(--text)] px-8 py-4 text-sm font-light text-[color:var(--bg)] hover:bg-[color:var(--text)]/90 transition-colors"
            >
              Obtener asistencia ahora
            </a>
            <a
              href="#plans"
              className="inline-flex items-center justify-center rounded-[33.5px]  bg-[color:var(--bg)] px-8 py-4 text-sm font-light text-[color:var(--text)] hover:bg-[color:var(--card)] transition-colors"
            >
              Ver planes
            </a>
          </div>
        </div>
      </header>

      <div className="w-full py-16 text-center text-[color:var(--text)] text-2xl font-light leading-8 font-abc">
        Atención personalizada para tu caballo.<br />
        Soporte 24/7. Sin filas. Sin tiempo de espera.
      </div>

      <section className="w-full px-6 py-28">
        <div className="mx-auto flex w-full max-w-[1600px] flex-col gap-6">
          <div className="grid grid-cols-1 gap-10 md:grid-cols-5 items-stretch">
            <div className="md:col-span-2 flex items-center">
              <h2 className="text-[color:var(--text)] text-3xl sm:text-6xl font-light font-abc">¿Cómo funciona?</h2>
            </div>


            <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
              <div className="w-px self-stretch bg-[color:var(--border)]" />
              <div className="flex flex-col gap-2">
                <div className="h-8 w-8 mb-2">
                  <Image src="/f3 1.svg" alt="Paso 1" width={20} height={20} className="icon-dark" />
                  <Image src="/lightmode/f3 1.svg" alt="Paso 1" width={20} height={20} className="icon-light" />
                </div>
                <div className="text-lg font-light leading-8 mb-6">
                  <span className="block">Cuéntanos el caso</span>

                </div>
                <p className="text-sm font-light leading-6 text-[color:var(--text)]">
                  Escribe lo que pasa. Nuestro asistente hace 2–3 preguntas clave para entender mejor.
                </p>
              </div>
            </div>

            <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
              <div className="w-px self-stretch bg-[color:var(--border)]" />
              <div className="flex flex-col gap-2">
                <div className="h-8 w-8 mb-2">
                  <Image src="/f6 1.svg" alt="Paso 2" width={20} height={20} className="icon-dark" />
                  <Image src="/lightmode/f6 1.svg" alt="Paso 2" width={20} height={20} className="icon-light" />
                </div>
                <div className="text-lg font-light leading-8 mb-6">
                  <span className="block">Conéctate con un vet</span>
                </div>
                <p className="text-sm font-light leading-6 text-[color:var(--text)]">
                  Te sugerimos chat o video según el caso. Pagas y entras a la consulta.
                </p>
              </div>
            </div>

            <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
              <div className="w-px self-stretch bg-[color:var(--border)]" />
              <div className="flex flex-col gap-2">
                <div className="h-8 w-8 mb-2">
                  <Image src="/f1 1.svg" alt="Paso 3" width={20} height={20} className="icon-dark" />
                  <Image src="/lightmode/f1 1.svg" alt="Paso 3" width={20} height={20} className="icon-light" />
                </div>
                <div className="text-lg font-light leading-8 mb-6">
                  <span className="block">Recibe un plan personalizado</span>

                </div>
                <p className="text-sm font-light leading-6 text-[color:var(--text)]">
                  Al terminar, te compartimos un plan de cuidado propuesto con próximos pasos.
                </p>
              </div>
            </div>
          </div>
        </div>
      </section>

      <main className="flex flex-col gap-16">

        <BenefitsSection />

        <div className="w-full flex items-center justify-center gap-4 px-6 py-18">
          <a
            href="#assist"
            className="inline-flex items-center justify-center rounded-[33.5px] bg-[color:var(--text)] px-8 py-4 text-sm font-light text-[color:var(--bg)] hover:bg-[color:var(--text)]/90 transition-colors"
          >
            Obtener asistencia ahora
          </a>
          <a
            href="#plans"
            className="inline-flex items-center justify-center rounded-[33.5px] border border-[color:var(--border)] bg-[color:var(--bg)] px-8 py-4 text-sm font-light text-[color:var(--text)] hover:bg-[color:var(--card)] transition-colors"
          >
            Ver planes
          </a>
        </div>


        <section id="nuestro-equipo" className="w-full px-6 py-16">
          <div className="mx-auto flex w-full max-w-[1600px] flex-col gap-6">
            <div className="grid grid-cols-1 gap-10 md:grid-cols-5 items-stretch">
              <div className="md:col-span-2 flex items-center">
                <h2 className="text-[color:var(--text)] text-3xl sm:text-3xl font-light font-abc">
                  Respaldado por los veterinarios especialistas más reconocidos del medio. Experiencia real en manejo equino.
                </h2>
              </div>

              <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                <div className="w-px self-stretch bg-[color:var(--border)]" />
                <div className="flex flex-col gap-2 h-full">
                  <div className="text-xl font-light leading-8 mb-6">
                    <span className="block">Manejo de cuadras y prevención</span>
                  </div>
                  <p className="text-sm font-light leading-6 text-[color:var(--text)] flex-1">
                    “Para cuadras con varios caballos, este tipo de atención digital ayuda muchísimo. Se evitan visitas innecesarias y se detectan a tiempo los casos que sí requieren atención presencial.”
                  </p>
                  <div className="mt-auto flex items-end gap-3 pt-4">
                    <div className="h-7 w-7 rounded-full bg-[color:var(--avatar-placeholder)]" />
                    <span className="text-sm font-light">Dra. María López</span>
                  </div>
                </div>
              </div>

              <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                <div className="w-px self-stretch bg-[color:var(--border)]" />
                <div className="flex flex-col gap-2 h-full">
                  <div className="text-xl font-light leading-8 mb-6">
                    <span className="block">Atención preventiva y seguimiento</span>
                  </div>
                  <p className="text-sm font-light leading-6 text-[color:var(--text)] flex-1">
                    “Me parece una herramienta muy valiosa para seguimiento. Muchos problemas reaparecen porque no hay acompañamiento después de la primera consulta. Aquí se puede dar continuidad real sin saturar al veterinario ni al dueño.”
                  </p>
                  <div className="mt-auto flex items-end gap-3 pt-4">
                    <div className="h-7 w-7 rounded-full bg-[color:var(--avatar-placeholder)]" />
                    <span className="text-sm font-light">Dr. Carlos Méndez</span>
                  </div>
                </div>
              </div>

              <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                <div className="w-px self-stretch bg-[color:var(--border)]" />
                <div className="flex flex-col gap-2 h-full">
                  <div className="text-xl font-light leading-8 mb-6">
                    <span className="block">Experiencia</span>
                  </div>
                  <p className="text-sm font-light leading-6 text-[color:var(--text)] flex-1">
                    “Call a Vet permite hacer un triage inicial mucho más ordenado. La mayoría de los casos que recibimos no requieren visita inmediata, pero sí una orientación clara para el dueño. Esta plataforma ayuda a tomar mejores decisiones desde el primer contacto.”
                  </p>
                  <div className="mt-auto flex items-end gap-3 pt-4">
                    <div className="h-7 w-7 rounded-full bg-[color:var(--avatar-placeholder)]" />
                    <span className="text-sm font-light">Dra. Laura Gómez</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>


        <div className="w-full py-6 text-center text-[color:var(--text)] text-2xl font-light leading-8 font-abc">
          Atención ética: plataforma impulsada por inteligencia artificial<br />
          que siempre deriva a atención humana.
        </div>
        <div className="w-full flex items-center justify-center gap-4 px-6">
          <a
            href="#assist"
            className="inline-flex items-center justify-center rounded-[33.5px] bg-[color:var(--text)] px-8 py-4 text-sm font-light text-[color:var(--bg)] hover:bg-[color:var(--text)]/90 transition-colors"
          >
            Obtener asistencia ahora
          </a>
          <a
            href="#plans"
            className="inline-flex items-center justify-center rounded-[33.5px] border border-[color:var(--border)] bg-[color:var(--bg)] px-8 py-4 text-sm font-light text-[color:var(--text)] hover:bg-[color:var(--card)] transition-colors"
          >
            Ver planes
          </a>
        </div>

        <section className="w-full px-6 py-28">
          <div className="mx-auto flex w-full max-w-[1600px] flex-col gap-6">
            <div className="grid grid-cols-1 gap-10 md:grid-cols-5 items-stretch">
              <div className="md:col-span-2 flex items-center">
                <h2 className="text-[color:var(--text)] text-xl sm:text-4xl font-light font-abc">Un solo evento puede pagar todo el mes.</h2>
              </div>


              <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                <div className="w-px self-stretch bg-[color:var(--border)]" />
                <div className="flex flex-col gap-3">
                  <div className="text-4xl font-light leading-8 mb-6">
                    <span className="block">$20,000</span>

                  </div>
                  <p className="text-sm font-light leading-6 text-[color:var(--text)]">
                    Más de $20,000 pesos de ahorro al mes - ahorro mensual real.
                  </p>
                </div>
              </div>

              <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                <div className="w-px self-stretch bg-[color:var(--border)]" />
                <div className="flex flex-col gap-3">
                  <div className="text-4xl font-light leading-8 mb-6">
                    <span className="block">15 Horas</span>
                  </div>
                  <p className="text-sm font-light leading-6 text-[color:var(--text)]">
                    Hasta 15 horas al mes recuperadas - tiempo operativo recuperado.
                  </p>
                </div>
              </div>

              <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                <div className="w-px self-stretch bg-[color:var(--border)]" />
                <div className="flex flex-col gap-3">
                  <div className="text-4xl font-light leading-8 mb-6">
                    <span className="block">5 Minutos</span>

                  </div>
                  <p className="text-sm font-light leading-6 text-[color:var(--text)]">
                    Respuesta en menos de 5 minutos - atención sin tiempos largos de espera.
                  </p>
                </div>
              </div>
            </div>

            <div className="grid grid-cols-1 gap-10 md:grid-cols-5 items-stretch mt-10">
              <div className="hidden md:block md:col-span-3" />

              <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                <div className="w-px self-stretch bg-[color:var(--border)]" />
                <div className="flex flex-col gap-3">
                  <div className="text-4xl font-light leading-8 mb-6">
                    <span className="block">70%</span>
                  </div>
                  <p className="text-sm font-light leading-6 text-[color:var(--text)]">
                    70% de los casos se resuelven sin visita física - menos urgencias mal atendidas.
                  </p>
                </div>
              </div>

              <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                <div className="w-px self-stretch bg-[color:var(--border)]" />
                <div className="flex flex-col gap-3">
                  <div className="text-4xl font-light leading-8 mb-6">
                    <span className="block">45x</span>
                  </div>
                  <p className="text-sm font-light leading-6 text-[color:var(--text)]">
                    Hasta 45x de retorno sobre el costo del plan - retorno inmediato.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section className="w-full px-6 py-2">
          <div className="mx-auto w-full max-w-[1600px] rounded-2xl p-6 sm:p-8 md:p-10">
            <div className="grid w-full gap-6 lg:grid-cols-5 items-start">
              <div className="lg:col-span-2 flex flex-col gap-2 text-[color:var(--text)] font-abc">
                <h2 className="text-3xl sm:text-4xl font-light">Call a Vet está diseñado para que ahorres desde la primera consulta.</h2>
                <p className="text-base sm:text-lg font-light text-[color:var(--text)]">
                  Ajusta tus variables y compara el ahorro mensual estimado antes de contratar.
                  Utiliza nuestro simulador y compruébalo:
                </p>
              </div>
            </div>
          </div>
        </section>


        <SavingsCalculator />

        <div className={`transition-opacity duration-1000 ease-out ${isFading ? "opacity-0" : "opacity-100"}`}>
          <section id="nuestro-equipo" className="w-full px-6 py-2">
            <div className="mx-auto w-full max-w-[1600px] rounded-2xl p-6 sm:p-8 md:p-10">
              <div className="grid w-full gap-6 lg:grid-cols-5 items-start">
                <div className="md:col-span-2 flex flex-col items-start gap-3">
                  <h2 className="text-[color:var(--text)] text-3xl sm:text-3xl font-light font-abc">
                    Nuestros planes:
                    Atención veterinaria pensada como un servicio, no como una emergencia.
                  </h2>
                  <p className="text-base sm:text-lg font-light text-[color:var(--text)]">
                    Desde un solo caballo hasta operaciones completas, sin contratos ni sorpresas.
                  </p>
                  <div className="mt-4 flex flex-col gap-2">
                    <div className="relative inline-flex items-center rounded-full border border-[color:var(--border)] bg-[color:var(--card)] p-1 text-sm font-light w-fit shadow-sm overflow-hidden">
                      <span
                        className="absolute top-1 bottom-1 rounded-full bg-[color:var(--text)] transition-all duration-250 ease-out"
                        style={{ width: `${thumbStyle.width}px`, left: `${thumbStyle.left}px` }}
                        aria-hidden
                      />
                      <button
                        type="button"
                        onClick={() => handleBillingChange("monthly")}
                        ref={monthlyRef}
                        className={`relative z-10 px-5 py-2 rounded-full transition-colors duration-900 ${billingCycle === "monthly" ? "text-[color:var(--bg)]" : "text-[color:var(--text)]"}`}
                        aria-pressed={billingCycle === "monthly"}
                      >
                        Mensual
                      </button>
                      <button
                        type="button"
                        onClick={() => handleBillingChange("annual")}
                        ref={annualRef}
                        className={`relative z-10 px-5 py-2 rounded-full transition-colors duration-900 ${billingCycle === "annual" ? "text-[color:var(--bg)]" : "text-[color:var(--text)]"}`}
                        aria-pressed={billingCycle === "annual"}
                      >
                        Anual
                      </button>
                    </div>
                    <p className="text-sm text-transparent bg-clip-text bg-gradient-to-r from-sky-400 to-emerald-400 drop-shadow-[0_0_10px_rgba(56,189,248,0.45)] drop-shadow-[0_0_14px_rgba(52,211,153,0.35)]">
                      Elige anual y ahorra hasta $6,000 MXN al año vs. mensual.
                    </p>
                  </div>
                </div>


                <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                  <div className="w-px self-stretch bg-[color:var(--border)]" />
                  <div className="flex flex-col gap-2 h-full max-w-xs md:max-w-sm">
                    <div className="flex flex-col gap-2 min-h-[136px]">
                      <h3 className="text-5xl font-light leading-7 text-[color:var(--text)]">Starter</h3>
                      <p className="text-2xl font-light leading-6 text-[color:var(--muted)] mt-auto">{getPrice("starter")}</p>
                    </div>

                    <div className="flex flex-col gap-1 text-[color:var(--text)] flex-1">
                      <span className="text-md font-light leading-6 py-4 text-[color:var(--text)]">Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.</span>

                      <span className="text-sm font-regular leading-6 py-4 text-[color:var(--text)]">Incluye:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">1 videollamada veterinaria al mes.<br />2 chats veterinarios al mes.<br />Pre-diagnóstico y direccionamiento con especialistas por medio de IA.<br />Historial clínico digital del caballo.<br />Planes de cuidado propuestos (gratis).</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Por qué conviene:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Una sola consulta digital puede evitar una visita física innecesaria que cuesta más que todo el plan.</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Resultado:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Tranquilidad, respuesta inmediata y ahorro desde el primer mes.</span>
                    </div>

                    <button
                      className="mt-6 inline-flex items-center justify-center rounded-full bg-[color:var(--text)] px-6 py-3 text-sm font-light text-[color:var(--bg)] hover:bg-[color:var(--text)]/90 transition-colors"
                      type="button"
                    >
                      Contratar Starter por {getPrice("starter")}
                    </button>
                  </div>
                </div>

                <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                  <div className="w-px self-stretch bg-[color:var(--border)]" />
                  <div className="flex flex-col gap-2 h-full max-w-xs md:max-w-sm">
                    <div className="flex flex-col gap-2 min-h-[136px]">
                      <h3 className="text-5xl font-light leading-7 text-[color:var(--text)]">Plus</h3>
                      <p className="text-2xl font-light leading-6 text-[color:var(--muted)] mt-auto">{getPrice("plus")}</p>
                    </div>

                    <div className="flex flex-col gap-1 text-[color:var(--text)] flex-1">
                      <span className="text-md font-light leading-6 py-4 text-[color:var(--text)]">Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.</span>

                      <span className="text-sm font-regular leading-6 py-4 text-[color:var(--text)]">Incluye:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">2 videollamadas veterinarias al mes.<br />3 chats veterinarios al mes.<br />Pre-diagnóstico y direccionamiento con especialistas por medio de IA.<br />Historial clínico digital del caballo.<br />Planes de cuidado propuestos personalizados.<br />Prioridad de atención media</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Por qué conviene:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Combina prevención + seguimiento continuo por menos de lo que cuesta una sola urgencia tradicional.</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Resultado:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Menos improvisación, mejores decisiones y control total de la salud del caballo.</span>
                    </div>

                    <button
                      className="mt-6 inline-flex items-center justify-center rounded-full bg-[color:var(--text)] px-6 py-3 text-sm font-light text-[color:var(--bg)] hover:bg-[color:var(--text)]/90 transition-colors"
                      type="button"
                    >
                      Contratar Plus por {getPrice("plus")}
                    </button>
                  </div>
                </div>

                <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                  <div className="w-px self-stretch bg-[color:var(--border)]" />
                  <div className="flex flex-col gap-2 h-full max-w-xs md:max-w-sm">
                    <div className="flex flex-col gap-2 min-h-[136px]">
                      <h3 className="text-5xl font-light leading-7 text-[color:var(--text)]">Cuadra 5</h3>
                      <p className="text-2xl font-light leading-6 text-[color:var(--muted)] mt-auto">{getPrice("cuadra5")}</p>
                    </div>

                    <div className="flex flex-col gap-1 text-[color:var(--text)] flex-1">
                      <span className="text-md font-light leading-6 py-4 text-[color:var(--text)]">Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.</span>

                      <span className="text-sm font-regular leading-6 py-4 text-[color:var(--text)]">Incluye:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Gestión de hasta 5 caballos en un solo plan.<br />6 chats veterinarios compartidos.<br />2 videollamadas veterinarias al mes.<br />Pre-diagnóstico y direccionamiento con especialistas por medio de IA.<br />Historial clínico individual por caballo.<br />Planes de cuidado propuestos por IA.<br />Atención prioritaria</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Impacto Real:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Reduce visitas físicas, optimiza tiempos y centraliza toda la información médica de la cuadra.</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Resultado:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Ahorros mensuales reales frente a atención tradicional fragmentada.</span>
                    </div>

                    <button
                      className="mt-6 inline-flex items-center justify-center rounded-full bg-[color:var(--text)] px-6 py-3 text-sm font-light text-[color:var(--bg)] hover:bg-[color:var(--text)]/90 transition-colors"
                      type="button"
                    >
                      Contratar Cuadra 5 por {getPrice("cuadra5")}
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </section>

          <section id="nuestro-equipo" className="w-full px-6">
            <div className="mx-auto w-full max-w-[1600px] rounded-2xl p-6 sm:p-8 md:p-10">
              <div className="grid w-full gap-6 lg:grid-cols-5 items-start">
                <div className="md:col-span-2 flex flex-col items-start gap-3">
                </div>

                <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                  <div className="w-px self-stretch bg-[color:var(--border)]" />
                  <div className="flex flex-col gap-2 h-full max-w-xs md:max-w-sm">
                    <div className="flex flex-col gap-2 min-h-[136px]">
                      <h3 className="text-5xl font-light leading-7 text-[color:var(--text)]">Cuadra 15</h3>
                      <p className="text-2xl font-light leading-6 text-[color:var(--muted)] mt-auto">{getPrice("cuadra15")}</p>
                    </div>

                    <div className="flex flex-col gap-1 text-[color:var(--text)] flex-1">
                      <span className="text-md font-light leading-6 py-4 text-[color:var(--text)]">Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.</span>

                      <span className="text-sm font-regular leading-6 py-4 text-[color:var(--text)]">Incluye:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Hasta 15 caballos bajo un mismo plan.<br />20 chats veterinarios mensuales.<br />6 videollamadas veterinarias.<br />Historial clínico avanzado por caballo.<br />Planes de cuidado propuestos y seguimiento.<br />Prioridad alta en atención</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Impacto Real:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Ahorros operativos significativos al reducir urgencias presenciales y tiempos muertos.</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Resultado:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Salud equina gestionada como sistema, no como emergencias aisladas.</span>
                    </div>

                    <button
                      className="mt-6 inline-flex items-center justify-center rounded-full bg-[color:var(--text)] px-6 py-3 text-sm font-light text-[color:var(--bg)] hover:bg-[color:var(--text)]/90 transition-colors"
                      type="button"
                    >
                      Contratar Cuadra 15 por {getPrice("cuadra15")}
                    </button>
                  </div>
                </div>

                <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                  <div className="w-px self-stretch bg-[color:var(--border)]" />
                  <div className="flex flex-col gap-2 h-full max-w-xs md:max-w-sm">
                    <div className="flex flex-col gap-2 min-h-[136px]">
                      <h3 className="text-5xl font-light leading-12 text-[color:var(--text)]">Pro Entrenador</h3>
                      <p className="text-2xl font-light leading-6 text-[color:var(--muted)] mt-auto">{getPrice("proEntrenador")}</p>
                    </div>

                    <div className="flex flex-col gap-1 text-[color:var(--text)] flex-1">
                      <span className="text-md font-light leading-6 py-4 text-[color:var(--text)]">Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.</span>

                      <span className="text-sm font-regular leading-6 py-4 text-[color:var(--text)]">Incluye:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">10 chats veterinarios al mes<br />3 videollamadas al mes<br />Pre-diagnóstico con IA para cada caso.<br />Seguimiento clínico continuo.<br />Historial estructurado por caballo.<br />Acceso preferente a veterinarios</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Por qué conviene:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Permite resolver múltiples situaciones al mes sin depender de visitas presenciales constantes.</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Resultado:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Más control, menos interrupciones operativas y mejor desempeño del equipo.</span>
                    </div>

                    <button
                      className="mt-6 inline-flex items-center justify-center rounded-full bg-[color:var(--text)] px-6 py-3 text-sm font-light text-[color:var(--bg)] hover:bg-[color:var(--text)]/90 transition-colors"
                      type="button"
                    >
                      Contratar Pro Entrenador por {getPrice("proEntrenador")}
                    </button>
                  </div>
                </div>

                <div className="flex items-start gap-4 text-[color:var(--text)] font-abc h-full">
                  <div className="w-px self-stretch bg-[color:var(--border)]" />
                  <div className="flex flex-col gap-2 h-full max-w-xs md:max-w-sm">
                    <div className="flex flex-col gap-2 min-h-[136px]">
                      <h3 className="text-5xl font-light leading-12 text-[color:var(--text)]">Rancho de Trabajo</h3>
                      <p className="text-2xl font-light leading-6 text-[color:var(--muted)] mt-auto">{getPrice("ranchoTrabajo")}</p>
                    </div>

                    <div className="flex flex-col gap-1 text-[color:var(--text)] flex-1">
                      <span className="text-md font-light leading-6 py-4 text-[color:var(--text)]">Ideal para: ranchos, centros de trabajo y operaciones intensivas.</span>

                      <span className="text-sm font-regular leading-6 py-4 text-[color:var(--text)]">Incluye:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Gestión de hasta 25 caballos.<br />25 chats veterinarios mensuales.<br />5 videollamadas incluidas.<br />Historial clínico completo y centralizado.<br />Planes de cuidado preventivos.<br />Atención prioritaria máxima</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Impacto Real:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Optimiza costos veterinarios, mejora la prevención y profesionaliza la toma de decisiones.</span>

                      <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">Resultado:</span>
                      <span className="text-sm font-light leading-6 text-[color:var(--muted)]">Menos urgencias, mejor planificación y control total de la operación.</span>
                    </div>

                    <button
                      className="mt-6 inline-flex items-center justify-center rounded-full bg-[color:var(--text)] px-6 py-3 text-sm font-light text-[color:var(--bg)] hover:bg-[color:var(--text)]/90 transition-colors"
                      type="button"
                    >
                      Contratar Rancho de Trabajo por {getPrice("ranchoTrabajo")}
                    </button>
                  </div>
                </div>
              </div>
            </div>
          </section>
        </div>

        <div className="w-full py-16 text-center text-[color:var(--text)] text-2xl font-light leading-8 font-abc">
          Sin cargos ocultos.<br />
          Puedes cambiar o cancelar cuando quieras.
        </div>

        <section id="faq" className="mx-auto w-full max-w-6xl px-6">
          <h2 className="text-3xl font-semibold mb-6">FAQ</h2>
          <p className="text-lg text-[color:var(--muted)]">Próximamente: preguntas frecuentes.</p>
        </section>

        <footer id="footer" className="mx-auto w-full max-w-6xl px-6 border-t border-[color:var(--border)] pt-10">
          <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between text-sm text-[color:var(--muted)]">
            <span>© {new Date().getFullYear()} Call a Vet</span>
            <div className="flex gap-4">
              <a href="#planes" className="hover:text-[color:var(--text)]">Planes</a>
              <a href="#faq" className="hover:text-[color:var(--text)]">FAQ</a>
              <a href="#como-funciona" className="hover:text-[color:var(--text)]">Cómo funciona</a>
            </div>
          </div>
        </footer>
      </main>
    </div>
  );
}