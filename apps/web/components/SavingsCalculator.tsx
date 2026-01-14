"use client";

import React from "react";

const fmt = new Intl.NumberFormat("es-MX", {
  style: "currency",
  currency: "MXN",
  maximumFractionDigits: 0,
});
const pct = (n: number) => `${(n * 100).toFixed(1)}%`;

function useNumberState(initial: number) {
  const [v, setV] = React.useState<number>(initial);
  const set = (n: number) => setV(Number.isFinite(n) ? n : 0);
  return {
    value: v,
    set,
    bind: {
      value: String(v),
      onChange: (e: React.ChangeEvent<HTMLInputElement>) => {
        const n = parseFloat(e.target.value.replace(",", "."));
        set(Number.isNaN(n) ? 0 : n);
      },
    },
  } as const;
}

function computeEquineClientROI(params: {
  horses: number;
  eventsPerHorse: number;
  resolution: number;
  onsiteCost: number;
  travelCost: number;
  hoursSaved: number;
  downtimeCost: number;
  membershipCost: number;
}) {
  const totalEvents = params.horses * params.eventsPerHorse;
  const avoidedVisits = totalEvents * params.resolution;
  const savingsVisits = avoidedVisits * (params.onsiteCost + params.travelCost);
  const savingsTime = totalEvents * params.hoursSaved * params.downtimeCost;
  const totalSavings = savingsVisits + savingsTime;
  const roi = params.membershipCost > 0 ? (totalSavings - params.membershipCost) / params.membershipCost : 0;
  const paybackMonths = totalSavings > 0 ? params.membershipCost / totalSavings : 0;
  return { totalEvents, avoidedVisits, savingsVisits, savingsTime, totalSavings, roi, paybackMonths };
}

export default function SavingsCalculator() {
  const horses = useNumberState(5);
  const eventsPerHorse = useNumberState(0.2);
  const resolution = useNumberState(0.6);
  const onsiteCost = useNumberState(2500);
  const travelCost = useNumberState(500);
  const hoursSaved = useNumberState(1.5);
  const downtimeCost = useNumberState(400);
  const membershipCost = useNumberState(999);

  const { totalEvents, avoidedVisits, savingsVisits, savingsTime, totalSavings, roi, paybackMonths } =
    computeEquineClientROI({
      horses: horses.value,
      eventsPerHorse: eventsPerHorse.value,
      resolution: resolution.value,
      onsiteCost: onsiteCost.value,
      travelCost: travelCost.value,
      hoursSaved: hoursSaved.value,
      downtimeCost: downtimeCost.value,
      membershipCost: membershipCost.value,
    });

  const paybackDays = paybackMonths ? paybackMonths * 30 : 0;

  const inputClass =
    "w-full rounded-lg border border-[color:var(--border)] bg-[color:var(--bg)] px-3 py-2 text-[color:var(--text)] focus:outline-none focus:ring-2 focus:ring-[color:var(--text)]/20";
  const labelClass = "text-sm font-light text-[color:var(--text)]";

  return (
    <section id="calculadora" className="w-full px-6 py-20">
      <div className="mx-auto w-full max-w-[1600px] rounded-2xl border border-[color:var(--border)] bg-[color:var(--benefits-bg)] p-6 sm:p-8 md:p-10">
        <div className="grid w-full gap-10 lg:grid-cols-5 items-start">
          <div className="lg:col-span-2 flex flex-col gap-8 text-[color:var(--text)] font-abc">
            <div>
              <div className="text-3xl sm:text-4xl font-light">Entradas</div>
              <div className="text-lg sm:text-xl font-light mt-2">Ajusta tu operación (costos locales, estacionalidad).</div>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div className="flex flex-col gap-1">
                <label className={labelClass}>Número de caballos</label>
                <input type="number" min={0} step="1" className={inputClass} {...horses.bind} />
              </div>
              <div className="flex flex-col gap-1">
                <label className={labelClass}>Eventos de triage / caballo (mes)</label>
                <input type="number" min={0} step="0.1" className={inputClass} {...eventsPerHorse.bind} />
              </div>
              <div className="flex flex-col gap-1">
                <label className={labelClass}>Tasa de resolución digital</label>
                <input type="number" min={0} max={1} step="0.05" className={inputClass} {...resolution.bind} />
              </div>
              <div className="flex flex-col gap-1">
                <label className={labelClass}>Costo visita en sitio (MXN)</label>
                <input type="number" min={0} step="50" className={inputClass} {...onsiteCost.bind} />
              </div>
              <div className="flex flex-col gap-1">
                <label className={labelClass}>Costo de traslado por visita (MXN)</label>
                <input type="number" min={0} step="50" className={inputClass} {...travelCost.bind} />
              </div>
              <div className="flex flex-col gap-1">
                <label className={labelClass}>Horas ahorradas por evento</label>
                <input type="number" min={0} step="0.5" className={inputClass} {...hoursSaved.bind} />
              </div>
              <div className="flex flex-col gap-1">
                <label className={labelClass}>Costo/hora de inactividad (MXN)</label>
                <input type="number" min={0} step="50" className={inputClass} {...downtimeCost.bind} />
              </div>
              <div className="flex flex-col gap-1">
                <label className={labelClass}>Costo membresía (MXN/mes)</label>
                <input type="number" min={0} step="50" className={inputClass} {...membershipCost.bind} />
              </div>
            </div>
          </div>

          <div className="lg:col-span-3 flex flex-col gap-8 text-[color:var(--text)] font-abc">
            <div>
              <div className="text-3xl sm:text-4xl font-light">Resultados</div>
              <div className="text-lg sm:text-xl font-light mt-2">Estimaciones mensuales.</div>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-3 gap-6">
              <ResultCard
                title="Eventos totales por mes"
                value={totalEvents.toFixed(2)}
                description="Casos estimados que atenderías cada mes."
              />
              <ResultCard
                title="Ahorro total estimado"
                value={fmt.format(totalSavings)}
                description="Ahorro mensual combinado (visitas evitadas + tiempo recuperado)."
              />
              <ResultCard
                title="Ahorro por tiempo"
                value={fmt.format(savingsTime)}
                description="Valor del tiempo recuperado cuando el caso se resuelve de forma digital."
                highlight
              />
              <ResultCard
                title="Payback (días)"
                value={paybackDays ? paybackDays.toFixed(1) : "—"}
                description="Días estimados para cubrir el costo mensual con los ahorros generados."
                dot
              />
              <ResultCard
                title="Visitas evitadas / mes"
                value={avoidedVisits.toFixed(2)}
                description="Traslados físicos evitados gracias a la resolución digital de casos."
                dot
              />
              <ResultCard
                title="Ahorro por visitas"
                value={fmt.format(savingsVisits)}
                description="Costos de consulta y traslado que dejas de pagar al resolver remoto."
                highlight
              />
              <ResultCard
                title="ROI mensual"
                value={pct(roi)}
                description="Retorno mensual estimado comparado contra el costo del plan."
              />
              <div className="flex items-center justify-center">
                <a
                  href="#plans"
                  className="inline-flex items-center justify-center rounded-[33.5px] bg-[color:var(--text)] px-8 py-4 text-sm font-regular text-[color:var(--bg)] transition-colors hover:bg-[color:var(--text)]/90"
                >
                  Contratar plan
                </a>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}

function ResultCard({
  title,
  value,
  description,
  highlight,
  dot,
}: {
  title: string;
  value: React.ReactNode;
  description?: string;
  highlight?: boolean;
  dot?: boolean;
}) {
  return (
    <div className="result-card flex flex-col gap-2 rounded-xl border border-[color:var(--border)] p-4">
      <div className="text-4xl sm:text-5xl font-light">{value}</div>
      <div className="h-px w-full bg-white/20" />
      <div className="flex items-center gap-2 text-sm font-light">
        {dot && <span className="h-1.5 w-1.5 flex-shrink-0 rounded-full bg-green-500 shadow-[0px_0px_4px_1px_rgba(0,255,30,0.25)]" />}
        <span>{description || title}</span>
      </div>
    </div>
  );
}
