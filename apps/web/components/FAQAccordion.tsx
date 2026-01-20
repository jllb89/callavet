"use client";

import { useState } from "react";

type FAQItem = {
  question: string;
  answer: string;
};

type Props = {
  faqs: FAQItem[];
  className?: string;
};

export default function FAQAccordion({ faqs, className }: Props) {
  const [open, setOpen] = useState<Set<string>>(new Set());

  const toggle = (question: string) => {
    setOpen((prev) => {
      const next = new Set(prev);
      next.has(question) ? next.delete(question) : next.add(question);
      return next;
    });
  };

  const containerClass = ["w-full", "max-w-[640px]", "space-y-4", className]
    .filter(Boolean)
    .join(" ");

  return (
    <div className={containerClass}>
      {faqs.map((faq) => {
        const isOpen = open.has(faq.question);
        return (
          <div key={faq.question} className={`faq-item ${isOpen ? "open" : ""}`}>
            <button
              type="button"
              className="faq-toggle group"
              onClick={() => toggle(faq.question)}
              aria-expanded={isOpen}
            >
              <span className="relative inline-block">
                <span className="faq-text text-xl font-light font-['ABC_Diatype']">{faq.question}</span>
                <span className="nav-underline" />
              </span>
              <span className={`faq-chevron ${isOpen ? "open" : ""}`} aria-hidden>
                {isOpen ? "–" : "+"}
              </span>
            </button>

            <div
              className={`faq-body ${isOpen ? "open" : ""}`}
              style={{
                maxHeight: isOpen ? "520px" : "0px",
                opacity: isOpen ? 1 : 0,
                overflow: "hidden",
                transition: "max-height 1000ms ease, opacity 400ms ease",
                transitionDelay: isOpen ? "0ms, 280ms" : "0ms, 0ms",
              }}
              aria-hidden={!isOpen}
            >
              <p className="faq-answer font-light">{faq.answer}</p>
            </div>
            <div className="faq-divider" />
          </div>
        );
      })}
    </div>
  );
}