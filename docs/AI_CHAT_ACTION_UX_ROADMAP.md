# AI Chat Action UX Roadmap

## Goal

Make the AI concierge chat unambiguous when the assistant moves from intake questions to service actions. Users should always know whether they should type an answer or tap an action chip.

The app must not use canned assistant answers. The OpenAI Responses API remains responsible for visible conversational copy. The app should own only state, validation, rendering, and product action labels.

## Current Problem

The current chat can mix two interaction modes in one assistant turn:

- The assistant asks pre-consult or urgency questions.
- The UI also shows service action chips because `recommendedService` is present.

That creates a confusing choice: the user may not know whether to answer the assistant message or tap a chip.

There is also a backend state issue. The gateway infers whether urgent intake was already asked by reading prior assistant text with regex. If the model asks valid questions using different wording, the gateway can fail to recognize that intake already happened and can let another question set appear alongside action chips.

## Principles

- Do not hardcode assistant answers.
- Do not store prewritten clinical or concierge copy for user-facing messages.
- Let the AI generate explanatory messages, questions, and transition copy.
- Let the app own interaction state, action visibility, entitlement gating, and stable product labels.
- Never show service activation chips while the user is expected to answer intake questions.
- Never show a numbered intake list and service activation chips in the same assistant turn.

## Phase 1: Explicit Interaction State

Status: complete on 2026-07-02.

Purpose: add a state field that separates intake turns from action turns.

Backend tasks:

- Completed: add `nextStep` to the strict AI chat response schema.
- Completed: allow only `interview`, `recommendation`, `activation`, `handoff`, or `payment`.
- Completed: update AI instructions so the model marks question turns as `interview` and service-choice turns as `recommendation` or `payment`.
- Completed: add a deterministic gateway guard that prevents `recommendedService` from surfacing while urgent intake questions remain active.
- Completed: keep all visible assistant copy AI-generated; gateway only adjusts metadata and unsafe mixed states.

Mobile tasks:

- Completed: parse `nextStep` and `intakeQuestions` in `_AiChatPayload`.
- Completed: hide action chips when `nextStep == interview`, when `intakeQuestions` are present, or when the action label indicates question-answering.
- Completed: keep existing legacy fallback behavior for old payloads.

Validation:

- Completed: `pnpm --filter @cav/gateway-api run build` passes.
- Completed: `flutter analyze lib/src/features/chat/presentation/chat_screen.dart` passes from `apps/mobile`.

## Phase 2: Reliable Intake Memory

Status: complete on 2026-07-02.

Purpose: stop relying on assistant text regex to know whether urgent intake was already asked.

Tasks:

- Completed: add optional metadata to `AiChatMessageInput` for prior assistant turns.
- Completed: send bounded metadata from mobile history: `nextStep`, `urgency`, `intakeQuestions`, and `recommendedService`.
- Completed: update `chatTurnState()` to use metadata first and regex only as fallback.
- Completed: track whether the latest user message is likely answering intake versus starting a new issue.

Acceptance criteria:

- Completed: after the user answers an intake question set, the gateway can recognize the prior interview turn even when question wording varies.
- Completed: different wording from the model no longer breaks the one-shot intake rule when metadata is present.

Validation:

- Completed: `pnpm --filter @cav/gateway-api run build` passes.
- Completed: `flutter analyze lib/src/features/chat/presentation/chat_screen.dart` passes from `apps/mobile`.

## Phase 3: Recommendation Turn Copy Contract

Status: complete on 2026-07-02.

Purpose: make the AI-generated message complement the action chips.

Tasks:

- Completed: add instructions that recommendation turns should explain that the user can choose from the shown service actions.
- Completed: require no numbered intake list when `nextStep` is `recommendation` or `payment`.
- Completed: prefer one short transition paragraph plus optional safety note.
- Completed: keep chip labels app-owned and copy AI-owned.

Acceptance criteria:

- Completed: a recommendation turn is normalized as transition copy, not another interview.
- Completed: assistant text and chips can reinforce each other because intake lists are removed from action turns.

Validation:

- Completed: `pnpm --filter @cav/gateway-api run build` passes.
- Completed: compiled-service smoke confirms recommendation turns remove intake list blocks and clear `intakeQuestions`.

## Phase 4: Action Chip Design And Labels

Status: complete on 2026-07-02.

Purpose: make chips feel like clear product actions.

Tasks:

- Completed: use stable app-owned labels: `Iniciar chat con veterinario`, `Iniciar videollamada con especialista`, `Agendar consulta por videollamada`.
- Completed: use stable commerce labels: `Comprar consulta por chat`, `Comprar consulta por videollamada`, `Mejorar mi plan`.
- Completed: keep the selected/recommended chip visually distinguished through existing selected state while preserving safe alternatives.
- Deferred: consider a compact helper caption above chips if user testing still shows ambiguity.

Acceptance criteria:

- Completed: labels are predictable and not model-generated.
- Completed: recommended action remains visually clear without hiding safe alternatives.

Validation:

- Completed: `flutter analyze lib/src/features/chat/presentation/chat_screen.dart` passes from `apps/mobile`.

## Phase 5: Fixtures, Evals, And Observability

Status: complete on 2026-07-02.

Purpose: prevent mixed-state regressions.

Tasks:

- Completed: add fixtures for urgent first turn, urgent answer turn, routine recommendation, generic vet request, and entitlement exhaustion in `docs/ai-chat-action-ux-fixtures.json`.
- Completed: assert `nextStep == interview` never exposes service actions.
- Completed: assert `nextStep == recommendation` and `nextStep == payment` have no `intakeQuestions` or numbered intake blocks.
- Completed: add `actionUx` metadata to `ai_events.response_payload`, including `nextStep`, `intakeQuestionCount`, `canShowActions`, `mixedQuestionActionState`, and action repair warnings.
- Completed: add `env/scripts/smoke-ai-chat-action-ux.sh` to validate the compiled gateway service against the fixtures.

Acceptance criteria:

- Completed: local fixture smoke fails if a payload contains both intake questions and action chips.
- Pending deployment: staging smoke should confirm real OpenAI turns produce clear state transitions after these changes are deployed.

Validation:

- Completed: `pnpm --filter @cav/gateway-api run build` passes.
- Completed: `bash env/scripts/smoke-ai-chat-action-ux.sh` passes.
- Completed: `flutter analyze lib/src/features/chat/presentation/chat_screen.dart` passes from `apps/mobile`.

## Recommended Next Step

Deploy the action UX changes, then run a staging smoke with the exact urgent-intake flow from the logs to verify the second turn shows transition copy plus service actions, not another numbered question set.