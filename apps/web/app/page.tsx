"use client";

import { useState } from "react";
import Image from "next/image";
import Navbar from "../components/Navbar";
import BenefitsSection from "../components/BenefitsSection";
import PricingGrid from "../components/PricingGrid";
import SavingsCalculator from "../components/SavingsCalculator";
import FAQAccordion from "../components/FAQAccordion";

export default function Home() {
  const [openFaqs, setOpenFaqs] = useState<Set<string>>(new Set());
  const faqs = [
    {
      question: "¿Y si es una emergencia real?",
      answer:
        "Mostramos una barra de alerta con signos de urgencia (sangrado abundante, convulsiones, dificultad respiratoria). En esos casos te recomendamos acudir de inmediato a un centro físico.",
    },
    {
      question: "Seguridad y privacidad",
      answer: "Ciframos tu información y cumplimos buenas prácticas de protección de datos.",
    },
    {
      question: "Soporte",
      answer: "WhatsApp y correo. Tiempo de respuesta típico: minutos.",
    },
    {
      question: "Migración y cambios",
      answer: "Puedes cambiar de plan o cancelar en cualquier momento.",
    },
    {
      question: "¿Puedo usar el chat sin video?",
      answer: "Sí. Puedes resolver muchas dudas por chat. Si el caso lo amerita, te sugerimos video.",
    },
    {
      question: "¿Qué pasa si me quedo sin chats o videos?",
      answer: "Puedes contratar un extra o subir de plan.",
    },
    {
      question: "¿Cómo funciona la facturación?",
      answer: "Pagas con tarjeta de forma segura. Generamos comprobante.",
    },
    {
      question: "¿Los planes incluyen varias mascotas/caballos?",
      answer: "Sí, especialmente Cuadra está pensado para varios pacientes.",
    },
    {
      question: "¿Cuándo recibo el plan de cuidado propuesto?",
      answer: "Al finalizar la consulta; también puedes solicitar uno desde el perfil del paciente.",
    },
  ];

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
                <div className="w-full max-w-[640px]">
                  <FAQAccordion faqs={faqs} />
                </div>
              </div>
              
            </div>
            <div className="faq-cta-row flex items-center justify-center gap-4 pt-40">
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
          <div className="brand-stamp text-center text-[400px] font-normal font-['ABC_Diatype']">Call a Vet</div>
        </section>

                <footer id="footer" className="footer-overlap w-full px-6 pt-10 pb-16">
                  <div className="footer-rich mx-auto w-full max-w-[1400px]">
                    <div className="grid gap-10 md:grid-cols-[1.6fr_1fr]">
                      <div className="space-y-6">
                        <div className="flex items-center gap-3 text-2xl font-normal font-['ABC_Diatype']">
                          <Image
                            src="/logo-navbar.svg"
                            alt="Call a Vet logo"
                            width={140}
                            height={140}
                            className="footer-logo footer-logo-dark"
                          />
                          <Image
                            src="/lightmode/logo-navbar%201.svg"
                            alt="Call a Vet logo"
                            width={140}
                            height={140}
                            className="footer-logo footer-logo-light"
                          />
                        </div>
                        <div className="space-y-2">
                          <div className="text-xl font-normal font-['ABC_Diatype'] leading-snug">¿Listo para atender a tu caballo en minutos?</div>
                          <div className="text-sm font-normal font-['ABC_Diatype'] leading-6">Chat o videollamada con vets verificados + plan de cuidado y seguimiento.</div>
                        </div>
                        <div className="flex flex-wrap items-center gap-3">
                          <a
                            href="#assist"
                            className="inline-flex items-center justify-center rounded-[33.5px] bg-black px-6 py-2 text-sm font-normal font-['ABC_Diatype'] text-white hover:bg-black/80"
                          >
                            Obtener asistencia ahora
                          </a>
                          <a
                            href="#plans"
                            className="inline-flex items-center justify-center rounded-[33.5px] bg-black px-6 py-2 text-sm font-normal font-['ABC_Diatype'] text-white hover:bg-black/80"
                          >
                            Ver planes
                          </a>
                        </div>
                        <div className="space-y-2 text-xs font-['ABC_Diatype'] leading-5">
                          <div className="font-medium">Aviso importante</div>
                          <div className="font-light">
                            Call a Vet brinda orientación veterinaria remota (chat o videollamada) con base en la información que compartes. No sustituye una consulta presencial ni un servicio de urgencias.
                          </div>
                          <div className="font-medium">Emergencias</div>
                          <div className="font-light">
                            Si tu caballo presenta dificultad para respirar, convulsiones, sangrado abundante, colapso, dolor intenso o cualquier señal de riesgo inmediato, acude de inmediato a un centro veterinario presencial.
                          </div>
                        </div>
                      </div>

                      <div className="flex flex-col gap-4 text-sm font-normal font-['ABC_Diatype'] md:items-end md:text-right md:ml-auto">
                        <a className="hover:opacity-80" href="#terms">Términos y Condiciones</a>
                        <a className="hover:opacity-80" href="#refunds">Política de Reembolsos</a>
                        <a className="hover:opacity-80" href="#contact">Contacto</a>
                        <a className="hover:opacity-80" href="#privacy">Aviso de Privacidad</a>
                        <a className="hover:opacity-80" href="#faq">Preguntas frecuentes</a>
                      </div>
                    </div>

                    <div className="mt-12 flex flex-wrap items-center justify-between gap-4 text-sm font-normal font-['ABC_Diatype']">
                      <span>© 2025 Call a Vet. Todos los derechos reservados.</span>
                      <div className="flex items-center gap-3 text-current">
                        <svg
                          xmlns="http://www.w3.org/2000/svg"
                          width="32"
                          height="32"
                          viewBox="0 0 24 24"
                          fill="currentColor"
                          aria-hidden
                        >
                          <path d="M20 0c2.2091 0 4 1.7909 4 4v16c0 2.2091-1.7909 4-4 4H4c-2.2091 0-4-1.7909-4-4V4c0-2.2091 1.7909-4 4-4Zm-4.8377 4h-2.7508v10.9209a2.3324 2.3324 0 0 1-3.0455 2.2209 2.3324 2.3324 0 0 1 1.4129-4.4459V9.8862a5.0812 5.0812 0 0 0-5.7481 5.5912 5.0805 5.0805 0 0 0 3.802 4.3668 5.0818 5.0818 0 0 0 5.423-2.0286c.5899-.8501.9062-1.86.9065-2.8947V9.3345A6.5666 6.5666 0 0 0 19 10.5614V7.83a3.796 3.796 0 0 1-2.0944-.6295 3.8188 3.8188 0 0 1-1.6852-2.5075 3.7856 3.7856 0 0 1-.058-.693Z" />
                        </svg>
                        <svg
                          xmlns="http://www.w3.org/2000/svg"
                          width="32"
                          height="32"
                          viewBox="0 0 24 24"
                          fill="currentColor"
                          aria-hidden
                        >
                          <path d="M20 0a4 4 0 0 1 4 4v16a4 4 0 0 1-4 4H4a4 4 0 0 1-4-4V4a4 4 0 0 1 4-4h16zm-4.89 4.5H8.9C6.33 4.5 4.6 6.15 4.5 8.66V15.09c0 1.3.42 2.41 1.27 3.23a4.34 4.34 0 0 0 2.88 1.17l.27.01h6.16c1.3 0 2.4-.42 3.18-1.18a4.25 4.25 0 0 0 1.23-2.95l.01-.26V8.9c0-1.28-.42-2.36-1.21-3.15a4.24 4.24 0 0 0-2.92-1.23l-.26-.01zm-6.2 1.4h6.24c.9 0 1.66.26 2.2.8.47.5.77 1.18.81 1.97V15.1c0 .94-.32 1.7-.87 2.21-.5.47-1.17.74-1.98.78H8.92c-.91 0-1.67-.26-2.21-.78-.5-.5-.77-1.17-.81-2V8.88c0-.9.26-1.66.8-2.2a2.98 2.98 0 0 1 2-.78h6.45-6.23zM12 8.1a3.88 3.88 0 0 0 0 7.74 3.88 3.88 0 0 0 0-7.74zm0 1.39a2.5 2.5 0 0 1 2.48 2.48A2.5 2.5 0 0 1 12 14.45a2.5 2.5 0 0 1-2.48-2.48A2.5 2.5 0 0 1 12 9.49zm4.02-2.36a.88.88 0 1 0 0 1.76.88.88 0 0 0 0-1.76z" />
                        </svg>
                      </div>
                    </div>
                  </div>
                </footer>
              </main>
            </div>
          );
        }