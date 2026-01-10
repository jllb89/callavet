import Image from "next/image";
import Navbar from "../components/Navbar";
import BenefitsSection from "../components/BenefitsSection";

export default function Home() {
  return (
    <div className="min-h-screen bg-[#101010] text-white">
      <header className="relative h-[1117px] w-screen overflow-hidden">
        <Image
          src="/bg-1.jpg"
          alt="Background"
          fill
          priority
          className="object-cover"
          sizes="100vw"
        />
        <div className="absolute inset-0 bg-gradient-to-b from-[#10101000] via-[#10101080] to-[#101010]" />

        <Navbar />

        <div className="absolute inset-0 flex flex-col items-center justify-end pb-[96px] px-6 text-center space-y-4">
          <div className="text-4xl font-light">Call a Vet</div>
          <p className="max-w-4xl text-2xl font-light">
            Plataforma de atención veterinaria especializada para tu caballo en minutos.
          </p>
          <p className="max-w-4xl text-md font-light">
            Describe el caso, nuestro asistente inteligente te guía con preguntas y te conectamos con un veterinario verificado.
            <br />
            Para dueños de caballos en México.
          </p>
          <div className="flex items-center gap-4 pt-10">
            <a
              href="#assist"
              className="inline-flex items-center justify-center rounded-[33.5px] bg-white px-8 py-4 text-sm font-light text-black hover:bg-white/90"
            >
              Obtener asistencia ahora
            </a>
            <a
              href="#plans"
              className="inline-flex items-center justify-center rounded-[33.5px] bg-black px-8 py-4 text-sm font-light text-white hover:bg-black/80"
            >
              Ver planes
            </a>
          </div>
        </div>
      </header>

      <div className="w-full py-16 text-center text-white text-2xl font-light leading-8 font-abc">
        Atención personalizada para tu caballo.<br />
        Soporte 24/7. Sin filas. Sin tiempo de espera.
      </div>

      <section className="w-full px-6 py-28">
        <div className="mx-auto flex w-full max-w-[1600px] flex-col gap-6">
          <div className="grid grid-cols-1 gap-10 md:grid-cols-5 items-stretch">
            <div className="md:col-span-2 flex items-center">
              <h2 className="text-white text-3xl sm:text-6xl font-light font-abc">¿Cómo funciona?</h2>
            </div>


            <div className="flex items-start gap-4 text-white font-abc h-full">
              <div className="w-px self-stretch bg-white/20" />
              <div className="flex flex-col gap-2">
                <div className="h-8 w-8 mb-2">
                  <Image src="/f3 1.svg" alt="Paso 1" width={20} height={20} />
                </div>
                <div className="text-lg font-light leading-8 mb-6">
                  <span className="block">Cuéntanos el caso</span>

                </div>
                <p className="text-sm font-light leading-6 text-white">
                  Escribe lo que pasa. Nuestro asistente hace 2–3 preguntas clave para entender mejor.
                </p>
              </div>
            </div>

            <div className="flex items-start gap-4 text-white font-abc h-full">
              <div className="w-px self-stretch bg-white/20" />
              <div className="flex flex-col gap-2">
                <div className="h-8 w-8 mb-2">
                  <Image src="/f6 1.svg" alt="Paso 2" width={20} height={20} />
                </div>
                <div className="text-lg font-light leading-8 mb-6">
                  <span className="block">Conéctate con un vet</span>
                </div>
                <p className="text-sm font-light leading-6 text-white">
                  Te sugerimos chat o video según el caso. Pagas y entras a la consulta.
                </p>
              </div>
            </div>

            <div className="flex items-start gap-4 text-white font-abc h-full">
              <div className="w-px self-stretch bg-white/20" />
              <div className="flex flex-col gap-2">
                <div className="h-8 w-8 mb-2">
                  <Image src="/f1 1.svg" alt="Paso 3" width={20} height={20} />
                </div>
                <div className="text-lg font-light leading-8 mb-6">
                  <span className="block">Recibe un plan personalizado</span>

                </div>
                <p className="text-sm font-light leading-6 text-white">
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
            className="inline-flex items-center justify-center rounded-[33.5px] bg-white px-8 py-4 text-sm font-light text-black hover:bg-white/90"
          >
            Obtener asistencia ahora
          </a>
          <a
            href="#plans"
            className="inline-flex items-center justify-center rounded-[33.5px] bg-black px-8 py-4 text-sm font-light text-white hover:bg-black/80"
          >
            Ver planes
          </a>
        </div>


        <section id="nuestro-equipo" className="w-full px-6 py-16">
          <div className="mx-auto flex w-full max-w-[1600px] flex-col gap-6">
            <div className="grid grid-cols-1 gap-10 md:grid-cols-5 items-stretch">
              <div className="md:col-span-2 flex items-center">
                <h2 className="text-white text-3xl sm:text-3xl font-light font-abc">
                  Respaldado por los veterinarios especialistas más reconocidos del medio. Experiencia real en manejo equino.
                </h2>
              </div>

              <div className="flex items-start gap-4 text-white font-abc h-full">
                <div className="w-px self-stretch bg-white/20" />
                <div className="flex flex-col gap-2 h-full">
                  <div className="text-xl font-light leading-8 mb-6">
                    <span className="block">Manejo de cuadras y prevención</span>
                  </div>
                  <p className="text-sm font-light leading-6 text-white flex-1">
                    “Para cuadras con varios caballos, este tipo de atención digital ayuda muchísimo. Se evitan visitas innecesarias y se detectan a tiempo los casos que sí requieren atención presencial.”
                  </p>
                  <div className="mt-auto flex items-end gap-3 pt-4">
                    <div className="h-7 w-7 rounded-full bg-white/15" />
                    <span className="text-sm font-light">Dra. María López</span>
                  </div>
                </div>
              </div>

              <div className="flex items-start gap-4 text-white font-abc h-full">
                <div className="w-px self-stretch bg-white/20" />
                <div className="flex flex-col gap-2 h-full">
                  <div className="text-xl font-light leading-8 mb-6">
                    <span className="block">Atención preventiva y seguimiento</span>
                  </div>
                  <p className="text-sm font-light leading-6 text-white flex-1">
                    “Me parece una herramienta muy valiosa para seguimiento. Muchos problemas reaparecen porque no hay acompañamiento después de la primera consulta. Aquí se puede dar continuidad real sin saturar al veterinario ni al dueño.”
                  </p>
                  <div className="mt-auto flex items-end gap-3 pt-4">
                    <div className="h-7 w-7 rounded-full bg-white/15" />
                    <span className="text-sm font-light">Dr. Carlos Méndez</span>
                  </div>
                </div>
              </div>

              <div className="flex items-start gap-4 text-white font-abc h-full">
                <div className="w-px self-stretch bg-white/20" />
                <div className="flex flex-col gap-2 h-full">
                  <div className="text-xl font-light leading-8 mb-6">
                    <span className="block">Experiencia</span>
                  </div>
                  <p className="text-sm font-light leading-6 text-white flex-1">
                    “Call a Vet permite hacer un triage inicial mucho más ordenado. La mayoría de los casos que recibimos no requieren visita inmediata, pero sí una orientación clara para el dueño. Esta plataforma ayuda a tomar mejores decisiones desde el primer contacto.”
                  </p>
                  <div className="mt-auto flex items-end gap-3 pt-4">
                    <div className="h-7 w-7 rounded-full bg-white/15" />
                    <span className="text-sm font-light">Dra. Laura Gómez</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>


        <div className="w-full py-10 text-center text-white text-2xl font-light leading-8 font-abc">
          Atención ética: plataforma impulsada por inteligencia artificial<br />
          que siempre deriva a atención humana.
        </div>
        <div className="w-full flex items-center justify-center gap-4 px-6">
          <a
            href="#assist"
            className="inline-flex items-center justify-center rounded-[33.5px] bg-white px-8 py-4 text-sm font-light text-black hover:bg-white/90"
          >
            Obtener asistencia ahora
          </a>
          <a
            href="#plans"
            className="inline-flex items-center justify-center rounded-[33.5px] bg-black px-8 py-4 text-sm font-light text-white hover:bg-black/80"
          >
            Ver planes
          </a>
        </div>

        <section className="w-full px-6 py-28">
        <div className="mx-auto flex w-full max-w-[1600px] flex-col gap-6">
          <div className="grid grid-cols-1 gap-10 md:grid-cols-5 items-stretch">
            <div className="md:col-span-2 flex items-center">
              <h2 className="text-white text-xl sm:text-4xl font-light font-abc">Un solo evento puede pagar todo el mes.</h2>
            </div>


            <div className="flex items-start gap-4 text-white font-abc h-full">
              <div className="w-px self-stretch bg-white/20" />
              <div className="flex flex-col gap-3">
                <div className="text-4xl font-light leading-8 mb-6">
                  <span className="block">$20,000</span>

                </div>
                <p className="text-sm font-light leading-6 text-white">
                  Más de $20,000 pesos de ahorro al mes - ahorro mensual real.
                </p>
              </div>
            </div>

            <div className="flex items-start gap-4 text-white font-abc h-full">
              <div className="w-px self-stretch bg-white/20" />
              <div className="flex flex-col gap-3">
                <div className="text-4xl font-light leading-8 mb-6">
                  <span className="block">15 Horas</span>
                </div>
                <p className="text-sm font-light leading-6 text-white">
                  Hasta 15 horas al mes recuperadas - tiempo operativo recuperado.
                </p>
              </div>
            </div>

            <div className="flex items-start gap-4 text-white font-abc h-full">
              <div className="w-px self-stretch bg-white/20" />
              <div className="flex flex-col gap-3">
                <div className="text-4xl font-light leading-8 mb-6">
                  <span className="block">5 Minutos</span>

                </div>
                <p className="text-sm font-light leading-6 text-white">
                  Respuesta en menos de 5 minutos - atención sin tiempos largos de espera.
                </p>
              </div>
            </div>
          </div>

          <div className="grid grid-cols-1 gap-10 md:grid-cols-5 items-stretch mt-10">
            <div className="hidden md:block md:col-span-3" />

            <div className="flex items-start gap-4 text-white font-abc h-full">
              <div className="w-px self-stretch bg-white/20" />
              <div className="flex flex-col gap-3">
                <div className="text-4xl font-light leading-8 mb-6">
                  <span className="block">70%</span>
                </div>
                <p className="text-sm font-light leading-6 text-white">
                  70% de los casos se resuelven sin visita física - menos urgencias mal atendidas.
                </p>
              </div>
            </div>

            <div className="flex items-start gap-4 text-white font-abc h-full">
              <div className="w-px self-stretch bg-white/20" />
              <div className="flex flex-col gap-3">
                <div className="text-4xl font-light leading-8 mb-6">
                  <span className="block">45x</span>
                </div>
                <p className="text-sm font-light leading-6 text-white">
                  Hasta 45x de retorno sobre el costo del plan - retorno inmediato.
                </p>
              </div>
            </div>
          </div>
        </div>
      </section>

        <section id="ahorro" className="mx-auto w-full max-w-6xl px-6">
          <h2 className="text-3xl font-semibold mb-6">Ahorro</h2>
          <p className="text-lg text-white/80">Próximamente: comparativos de ahorro.</p>
        </section>

        <section id="planes" className="mx-auto w-full max-w-6xl px-6">
          <h2 className="text-3xl font-semibold mb-6">Planes</h2>
          <p className="text-lg text-white/80">Próximamente: detalles de planes.</p>
        </section>

        <section id="faq" className="mx-auto w-full max-w-6xl px-6">
          <h2 className="text-3xl font-semibold mb-6">FAQ</h2>
          <p className="text-lg text-white/80">Próximamente: preguntas frecuentes.</p>
        </section>

        <footer id="footer" className="mx-auto w-full max-w-6xl px-6 border-t border-white/10 pt-10">
          <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between text-sm text-white/70">
            <span>© {new Date().getFullYear()} Call a Vet</span>
            <div className="flex gap-4">
              <a href="#planes" className="hover:text-white">Planes</a>
              <a href="#faq" className="hover:text-white">FAQ</a>
              <a href="#como-funciona" className="hover:text-white">Cómo funciona</a>
            </div>
          </div>
        </footer>
      </main>
    </div>
  );
}
