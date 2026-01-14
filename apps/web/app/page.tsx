"use client";

import Image from "next/image";
import Navbar from "../components/Navbar";
import BenefitsSection from "../components/BenefitsSection";
import PricingGrid from "../components/PricingGrid";
import SavingsCalculator from "../components/SavingsCalculator";

export default function Home() {
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

        <section className="w-full px-6">
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
        <PricingGrid />

        <div className="w-full py-16 text-center text-[color:var(--text)] text-2xl font-light leading-8 font-abc">
          Sin cargos ocultos.<br />
          Puedes cambiar o cancelar cuando quieras.
        </div>

        <section className="w-full px-6 py-2">
          <div
            className="relative mx-auto w-full max-w-[1600px] h-[60vh] rounded-2xl overflow-hidden bg-cover bg-center bg-no-repeat p-6 sm:p-8 md:p-10"
            style={{
              backgroundImage:
                "linear-gradient(90deg, rgba(17,17,17,0.7) 0%, rgba(17,17,17,0) 100%), url('/mockup5.png')",
              backgroundSize: "cover",
              backgroundPosition: "center center",
              backgroundRepeat: "no-repeat",
            }}
            aria-label="Simulador de ahorro Call a Vet"
            role="img"
          >
            <div className="grid w-full h-full gap-6 lg:grid-cols-5 items-center">
              <div className="lg:col-span-2 flex flex-col gap-2 justify-center text-white font-abc">
                <h2 className="text-3xl sm:text-4xl font-light text-white">Call a Vet no es solo <br />“hablar con un veterinario”.</h2>
                <p className="text-base sm:text-lg font-light text-white">
                  Es una forma más inteligente, rápida y rentable de gestionar la salud equina, diseñada para quienes necesitan respuestas claras, control y previsibilidad.
                </p>
              </div>
            </div>
            <div className="pointer-events-none absolute inset-0 rounded-2xl border border-[color:var(--border)]" aria-hidden />
          </div>
        </section>

        <section
          id="faq"
          className="w-full px-0 faq-section"
        >
          <div className="mx-auto w-full max-w-[1600px] px-6 py-16 sm:py-20 md:py-24">
            <div className="grid w-full gap-6 lg:grid-cols-5 items-start">
              <div className="lg:col-span-2 flex flex-col gap-2 text-[color:var(--text)] font-abc">
                <h2 className="text-3xl sm:text-4xl font-light">Preguntas frecuentes:<br />¿Funciona para mi cuadra? Sí, y aquí te explicamos por qué.</h2>
                <p className="text-base sm:text-lg font-light text-[color:var(--text)]">
                  Respuestas claras para dueños de cuadras, entrenadores y operaciones equinas.
                </p>
              </div>
            </div>

            <div className="grid w-full gap-6 lg:grid-cols-5 items-start pt-12">
              <div className="hidden lg:block" />
              <div className="hidden lg:block" />
              <div className="hidden lg:block" />
              <div className="lg:col-span-2 flex justify-center lg:justify-end">
                <div className="relative w-full max-w-[531px] h-[600px]">
                  <div className="absolute left-[275px] top-0 justify-start text-xl font-light font-['ABC_Diatype'] faq-text group">
                    <span className="relative inline-block">
                      ¿Y si es una emergencia real?
                      <span className="nav-underline" />
                    </span>
                  </div>
                  <div className="faq-divider absolute left-0 top-[55px]" />
                  <div className="absolute left-[257px] top-[415px] justify-start text-xl font-light font-['ABC_Diatype'] faq-text group">
                    <span className="relative inline-block">
                      ¿Cómo funciona la facturación?
                      <span className="nav-underline" />
                    </span>
                  </div>
                  <div className="faq-divider absolute left-0 top-[465px]" />
                  <div className="absolute left-[349px] top-[205px] justify-start text-xl font-light font-['ABC_Diatype'] faq-text group">
                    <span className="relative inline-block">
                      Migración y cambios
                      <span className="nav-underline" />
                    </span>
                  </div>
                  <div className="faq-divider absolute left-0 top-[254px]" />
                  <div className="absolute left-[331px] top-[68px] justify-start text-xl font-light font-['ABC_Diatype'] faq-text group">
                    <span className="relative inline-block">
                      Seguridad y privacidad
                      <span className="nav-underline" />
                    </span>
                  </div>
                  <div className="faq-divider absolute left-0 top-[117px]" />
                  <div className="absolute left-[206px] top-[491px] justify-start text-xl font-light font-['ABC_Diatype'] faq-text group">
                    <span className="relative inline-block">
                      ¿Los planes incluyen varios caballos?
                      <span className="nav-underline" />
                    </span>
                  </div>
                  <div className="faq-divider absolute left-0 top-[541px]" />
                  <div className="absolute left-[124px] top-[561px] justify-start text-xl font-light font-['ABC_Diatype'] faq-text group">
                    <span className="relative inline-block">
                      ¿Cuándo recibo el plan de cuidado propuesto?
                      <span className="nav-underline" />
                    </span>
                  </div>
                  <div className="faq-divider absolute left-0 top-[611px]" />
                  <div className="absolute left-[267px] top-[268px] justify-start text-xl font-light font-['ABC_Diatype'] faq-text group">
                    <span className="relative inline-block">
                      ¿Puedo usar el chat sin video?
                      <span className="nav-underline" />
                    </span>
                  </div>
                  <div className="faq-divider absolute left-0 top-[313px]" />
                  <div className="absolute left-[460px] top-[134px] justify-start text-xl font-light font-['ABC_Diatype'] faq-text group">
                    <span className="relative inline-block">
                      Soporte
                      <span className="nav-underline" />
                    </span>
                  </div>
                  <div className="faq-divider absolute left-0 top-[186px]" />
                  <div className="absolute left-[156px] top-[335px] justify-start text-xl font-light font-['ABC_Diatype'] faq-text group">
                    <span className="relative inline-block">
                      ¿Qué pasa si me quedo sin chats o videos?
                      <span className="nav-underline" />
                    </span>
                  </div>
                  <div className="faq-divider absolute left-0 top-[383px]" />
                </div>
              </div>
            </div>
          </div>
        </section>

        <footer id="footer" className="mx-auto w-full max-w-6xl px-6 border-t border-[color:var(--border)] pt-10">
          <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between text-sm text-[color:var(--muted)]">
            <span>© {new Date().getFullYear()} Call a Vet</span>
            <div className="flex gap-4">
              <a href="#plans" className="hover:text-[color:var(--text)]">Planes</a>
              <a href="#faq" className="hover:text-[color:var(--text)]">FAQ</a>
              <a href="#como-funciona" className="hover:text-[color:var(--text)]">Cómo funciona</a>
            </div>
          </div>
        </footer>
      </main>
    </div>
  );
}