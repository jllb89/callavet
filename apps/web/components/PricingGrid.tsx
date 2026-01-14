"use client";

import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";

type BillingCycle = "monthly" | "annual";
type PlanKey =
  | "starter"
  | "plus"
  | "cuadra5"
  | "cuadra15"
  | "proEntrenador"
  | "ranchoTrabajo";

type PlanContent = {
  title: string;
  summary: string;
  includes: string[];
  rationaleTitle: string;
  rationale: string;
  resultTitle: string;
  result: string;
};

const planCopy: Record<PlanKey, PlanContent> = {
  starter: {
    title: "Starter",
    summary: "Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.",
    includes: [
      "1 videollamada veterinaria al mes.",
      "2 chats veterinarios al mes.",
      "Pre-diagnóstico y direccionamiento con especialistas por medio de IA.",
      "Historial clínico digital del caballo.",
      "Planes de cuidado propuestos (gratis).",
    ],
    rationaleTitle: "Por qué conviene:",
    rationale: "Una sola consulta digital puede evitar una visita física innecesaria que cuesta más que todo el plan.",
    resultTitle: "Resultado:",
    result: "Tranquilidad, respuesta inmediata y ahorro desde el primer mes.",
  },
  plus: {
    title: "Plus",
    summary: "Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.",
    includes: [
      "2 videollamadas veterinarias al mes.",
      "3 chats veterinarios al mes.",
      "Pre-diagnóstico y direccionamiento con especialistas por medio de IA.",
      "Historial clínico digital del caballo.",
      "Planes de cuidado propuestos personalizados.",
      "Prioridad de atención media",
    ],
    rationaleTitle: "Por qué conviene:",
    rationale: "Combina prevención + seguimiento continuo por menos de lo que cuesta una sola urgencia tradicional.",
    resultTitle: "Resultado:",
    result: "Menos improvisación, mejores decisiones y control total de la salud del caballo.",
  },
  cuadra5: {
    title: "Cuadra 5",
    summary: "Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.",
    includes: [
      "Gestión de hasta 5 caballos en un solo plan.",
      "6 chats veterinarios compartidos.",
      "2 videollamadas veterinarias al mes.",
      "Pre-diagnóstico y direccionamiento con especialistas por medio de IA.",
      "Historial clínico individual por caballo.",
      "Planes de cuidado propuestos por IA.",
      "Atención prioritaria",
    ],
    rationaleTitle: "Impacto Real:",
    rationale: "Reduce visitas físicas, optimiza tiempos y centraliza toda la información médica de la cuadra.",
    resultTitle: "Resultado:",
    result: "Ahorros mensuales reales frente a atención tradicional fragmentada.",
  },
  cuadra15: {
    title: "Cuadra 15",
    summary: "Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.",
    includes: [
      "Hasta 15 caballos bajo un mismo plan.",
      "20 chats veterinarios mensuales.",
      "6 videollamadas veterinarias.",
      "Historial clínico avanzado por caballo.",
      "Planes de cuidado propuestos y seguimiento.",
      "Prioridad alta en atención",
    ],
    rationaleTitle: "Impacto Real:",
    rationale: "Ahorros operativos significativos al reducir urgencias presenciales y tiempos muertos.",
    resultTitle: "Resultado:",
    result: "Salud equina gestionada como sistema, no como emergencias aisladas.",
  },
  proEntrenador: {
    title: "Pro Entrenador",
    summary: "Ideal para dueños individuales que quieren orientación rápida sin pagar visitas innecesarias.",
    includes: [
      "10 chats veterinarios al mes",
      "3 videollamadas al mes",
      "Pre-diagnóstico con IA para cada caso.",
      "Seguimiento clínico continuo.",
      "Historial estructurado por caballo.",
      "Acceso preferente a veterinarios",
    ],
    rationaleTitle: "Por qué conviene:",
    rationale: "Permite resolver múltiples situaciones al mes sin depender de visitas presenciales constantes.",
    resultTitle: "Resultado:",
    result: "Más control, menos interrupciones operativas y mejor desempeño del equipo.",
  },
  ranchoTrabajo: {
    title: "Rancho de Trabajo",
    summary: "Ideal para: ranchos, centros de trabajo y operaciones intensivas.",
    includes: [
      "Gestión de hasta 25 caballos.",
      "25 chats veterinarios mensuales.",
      "5 videollamadas incluidas.",
      "Historial clínico completo y centralizado.",
      "Planes de cuidado preventivos.",
      "Atención prioritaria máxima",
    ],
    rationaleTitle: "Impacto Real:",
    rationale: "Optimiza costos veterinarios, mejora la prevención y profesionaliza la toma de decisiones.",
    resultTitle: "Resultado:",
    result: "Menos urgencias, mejor planificación y control total de la operación.",
  },
};

export default function PricingGrid() {
  const [billingCycle, setBillingCycle] = useState<BillingCycle>("monthly");
  const [isFading, setIsFading] = useState(false);
  const monthlyRef = useRef<HTMLButtonElement>(null);
  const annualRef = useRef<HTMLButtonElement>(null);
  const [thumbStyle, setThumbStyle] = useState<{ width: number; left: number }>({ width: 0, left: 0 });

  const priceTable = useMemo(
    () => ({
      starter: { monthly: "$999 al mes", annual: "$899 al mes" },
      plus: { monthly: "$1,899 al mes", annual: "$1,699 al mes" },
      cuadra5: { monthly: "$2,499 al mes", annual: "$2,299 al mes" },
      cuadra15: { monthly: "$3,499 al mes", annual: "$3,099 al mes" },
      proEntrenador: { monthly: "$2,499 al mes", annual: "$2,299 al mes" },
      ranchoTrabajo: { monthly: "$4,999 al mes", annual: "$4,499 al mes" },
    }),
    []
  );

  const getPrice = (plan: PlanKey) => priceTable[plan][billingCycle];

  const renderPrice = (plan: PlanKey) => (
    <div className="mt-auto flex flex-col leading-6">
      <span className="text-xl sm:text-2xl font-light text-[color:var(--muted)]">{getPrice(plan)}</span>
      {billingCycle === "annual" && (
        <span className="text-xs font-light text-[color:var(--muted)]/80">Facturación anual</span>
      )}
    </div>
  );

  const handleBillingChange = (cycle: BillingCycle) => {
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

  const gridPlacements: Array<{ plan: PlanKey; col: number; row: number }> = [
    { plan: "starter", col: 3, row: 1 },
    { plan: "plus", col: 4, row: 1 },
    { plan: "cuadra5", col: 5, row: 1 },
    { plan: "cuadra15", col: 3, row: 2 },
    { plan: "proEntrenador", col: 4, row: 2 },
    { plan: "ranchoTrabajo", col: 5, row: 2 },
  ];

  return (
    <div className={`transition-opacity duration-1000 ease-out ${isFading ? "opacity-0" : "opacity-100"}`}>
      <section id="plans" className="w-full px-6 py-2">
        <div className="mx-auto w-full max-w-[1600px] rounded-2xl p-6 sm:p-8 md:p-10">
          <div className="grid w-full gap-8 lg:gap-y-32 lg:grid-cols-5 items-start">
            <div className="lg:col-start-1 lg:col-span-2 lg:row-start-1 flex flex-col items-start gap-3 lg:sticky lg:top-24">
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

            <div className="hidden lg:block lg:col-start-1 lg:row-start-2" aria-hidden />
            <div className="hidden lg:block lg:col-start-2 lg:row-start-2" aria-hidden />

            {gridPlacements.map(({ plan, col, row }) => (
              <PlanCard
                key={`${plan}-${row}-${col}`}
                planKey={plan}
                content={planCopy[plan]}
                renderPrice={renderPrice}
                billingCycle={billingCycle}
                getPrice={getPrice}
                className={`lg:col-start-${col} lg:row-start-${row}`}
              />
            ))}
          </div>
        </div>
      </section>
    </div>
  );
}

type PlanCardProps = {
  planKey: PlanKey;
  content: PlanContent;
  renderPrice: (plan: PlanKey) => ReactNode;
  billingCycle: BillingCycle;
  getPrice: (plan: PlanKey) => string;
  className?: string;
};

function PlanCard({ planKey, content, renderPrice, billingCycle, getPrice, className }: PlanCardProps) {
  return (
    <div className={`flex items-start gap-4 text-[color:var(--text)] font-abc h-full ${className ?? ""}`}>
      <div className="w-px self-stretch bg-[color:var(--border)]" />
      <div className="flex flex-col gap-2 h-full w-full">
        <div className="flex flex-col gap-2 min-h-[136px]">
          <h3 className="text-3xl font-light leading-7 text-[color:var(--text)]">{content.title}</h3>
          {renderPrice(planKey)}
        </div>

        <div className="flex flex-col gap-1 text-[color:var(--text)] flex-1">
          <span className="text-md font-light leading-6 py-4 text-[color:var(--text)]">{content.summary}</span>

          <span className="text-sm font-regular leading-6 py-4 text-[color:var(--text)]">Incluye:</span>
          <div className="text-sm font-light leading-6 text-[color:var(--muted)]">
            {content.includes.map((line, idx) => (
              <span key={`${planKey}-${idx}`} className="block">
                {line}
                {idx < content.includes.length - 1 && <br />}
              </span>
            ))}
          </div>

          <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">{content.rationaleTitle}</span>
          <span className="text-sm font-light leading-6 text-[color:var(--muted)]">{content.rationale}</span>

          <span className="text-sm font-medium leading-6 py-4 text-[color:var(--text)]">{content.resultTitle}</span>
          <span className="text-sm font-light leading-6 text-[color:var(--muted)]">{content.result}</span>
        </div>

        <button
          className="mt-6 inline-flex items-center justify-center rounded-full bg-[color:var(--text)] px-6 py-3 text-sm font-light text-[color:var(--bg)] hover:bg-[color:var(--text)]/90 transition-colors"
          type="button"
        >
          Contratar por {getPrice(planKey)}
        </button>
        {billingCycle === "annual" && (
          <p className="text-xs font-light text-[color:var(--muted)]/80 text-center mt-2">Facturación anual</p>
        )}
      </div>
    </div>
  );
}
