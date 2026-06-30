# AI Chat Response Formatting Roadmap

## Goal

Make AI concierge responses render cleanly and predictably in chat, especially paragraphs, skipped lines, numbered intake questions, bullet lists, and urgent safety copy.

The core change is to stop treating the visible AI response as one decorated string. The gateway should return a structured display contract, and Flutter should render that contract with deterministic chat UI widgets.

## Current Inventory

- Gateway chat turns are handled in `services/gateway-api/src/modules/ai/ai.service.ts` through `POST /ai/chat/turn`.
- The gateway already uses the OpenAI Responses API with strict `text.format.json_schema` for chat turns.
- The current chat payload exposes one visible `message` string plus metadata such as `urgency`, `recommendedService`, `intakeQuestions`, `caseSummary`, `handoffSummary`, and `commerceRecommendation`.
- Urgent intake questions are sometimes appended server-side as newline-delimited numbered text.
- Mobile renders assistant bubbles in `apps/mobile/lib/src/features/chat/presentation/chat_screen.dart` using plain `Text(...)`.
- Mobile has `_readableAssistantText(...)`, but it is regex post-processing after the response has already been flattened into one string.
- Vet chat in `apps/vet/lib/src/features/chat/presentation/vet_chat_screen.dart` also renders raw content with plain `Text(...)` and should be considered a later consumer of the same formatting approach.

## Problem Statement

Formatting is currently split across prompt behavior, backend string assembly, and mobile regex cleanup. That makes the UI sensitive to small model variations:

- Numbered lists can collapse into one paragraph.
- Extra blank lines can appear before or after numbered items.
- Markdown markers like `**` may leak into the app.
- Urgent question sets can be duplicated between `message` and `intakeQuestions`.
- Flutter cannot distinguish a paragraph from a list item because both arrive as raw text.

The root fix is a typed display model. Prompt tuning and regex cleanup should support the contract, not be the contract.

## Reference Guidance

- OpenAI Structured Outputs: `https://developers.openai.com/api/docs/guides/structured-outputs`
  - Use strict JSON schemas when the app needs predictable UI-shaped output.
  - Use `additionalProperties: false`.
  - Treat optional fields as required fields that can be `null`.
  - Structured output is better than plain JSON mode when the UI depends on stable fields.
- OpenAI Text Generation: `https://developers.openai.com/api/docs/guides/text`
  - Responses API is recommended for current text generation work.
  - Prompt changes should be covered by representative tests and evals.
- Flutter rendering guidance:
  - Plain `Text` preserves explicit newlines but does not understand list semantics.
  - For this clinical chat surface, prefer a small custom renderer over arbitrary Markdown rendering so list spacing, wrapping, and safety styles stay controlled.

## Target Response Contract

Keep `message` for backwards compatibility, but add `formatVersion` and `displayBlocks` as the source of truth for new clients.

```json
{
  "message": "Plain-text fallback for legacy clients.",
  "formatVersion": 1,
  "displayBlocks": [
    {
      "type": "paragraph",
      "text": "Esto puede requerir valoracion veterinaria hoy.",
      "items": []
    },
    {
      "type": "numbered_list",
      "text": null,
      "items": [
        "Desde cuando empezo y ha empeorado?",
        "Ha tomado agua y ha hecho heces?",
        "Tiene fiebre, encias palidas, respiracion agitada o esta muy decaido?"
      ]
    }
  ],
  "urgency": "urgent",
  "recommendedService": null,
  "actionLabel": "Responder preguntas de urgencia",
  "safetyEscalation": true,
  "intakeQuestions": [
    "Desde cuando empezo y ha empeorado?",
    "Ha tomado agua y ha hecho heces?",
    "Tiene fiebre, encias palidas, respiracion agitada o esta muy decaido?"
  ],
  "caseSummary": "...",
  "handoffSummary": "...",
  "routingRationale": "...",
  "commerceRecommendation": "ask_more"
}
```

Supported block types for phase 1:

- `paragraph`: one short paragraph of assistant copy.
- `numbered_list`: ordered items rendered by Flutter with stable numbering.
- `bullet_list`: unordered items for short options or non-urgent checklist copy.
- `safety_note`: concise escalation or emergency-care note with restrained visual emphasis.

Schema rules:

- Root object remains strict and uses `additionalProperties: false`.
- Every field is required for OpenAI schema compatibility.
- `text` is `string | null`.
- `items` is always an array and is empty for non-list blocks.
- List item strings must not include manual prefixes like `1.`, `1)`, `-`, or bullet glyphs.
- `message` is generated as a plain-text fallback from the same block content.

## Implementation Phases

### Phase 0: Baseline And Fixtures

Status: complete on 2026-06-30.

Purpose: capture the current failure modes before changing behavior.

Fixture file: `docs/ai-chat-response-formatting-fixtures.json`.

Tasks:

- Completed: collected 6 synthetic bad-output fixtures covering line skipping, collapsed numbering, Markdown leakage, duplicate urgent questions, invented symptom formatting, and run-on service options.
- Completed: added fixture examples for urgent appetite/colic-like intake, lameness intake, generic vet request, post-intake routing, and entitlement-exhausted routing.
- Completed: recorded expected `formatVersion`, `displayBlocks`, and legacy `message` fallback assertions for each fixture.
- Completed: decided fixtures live first in a docs JSON file, then move into gateway formatter tests and jq-backed chat-turn smoke scripts once those implementation surfaces exist.

Acceptance criteria:

- Completed: each known formatting failure has at least one fixture in `docs/ai-chat-response-formatting-fixtures.json`.
- Completed: expected output is defined as structured blocks, not a raw string snapshot only.
- Completed: legacy `message` fallback expectations are included for every case.

Validation:

- Completed: fixture data is synthetic and marked as containing no user IDs, emails, phone numbers, tokens, or real customer details.
- Completed: `jq empty docs/ai-chat-response-formatting-fixtures.json` passes.
- Completed: `git diff --check -- docs/AI_CHAT_RESPONSE_FORMATTING_ROADMAP.md docs/ai-chat-response-formatting-fixtures.json` passes.

### Phase 1: Gateway Display Contract

Status: complete on 2026-06-30.

Purpose: make the Responses API return UI-shaped content.

Tasks:

- Completed: extended `chatTurnResponseFormat()` in `services/gateway-api/src/modules/ai/ai.service.ts` with `formatVersion` and `displayBlocks`.
- Completed: added a strict block schema for `paragraph`, `numbered_list`, `bullet_list`, and `safety_note` blocks.
- Completed: updated `chatTurnInstructions()` to explain that `displayBlocks` is the UI source of truth.
- Completed: instructed the model not to include list markers inside list item strings.
- Completed: instructed the model to use `numbered_list` for urgent triage questions.
- Completed: kept `message` as a plain-text fallback composed from the same block content.
- Completed: aligned deterministic dry-run and provider-fallback payloads with the same display contract fields.

Acceptance criteria:

- Completed: `/ai/chat/turn` still returns the existing fields.
- Completed: new clients can read `payload.displayBlocks` and `payload.formatVersion` on provider, dry-run, and deterministic fallback paths.
- Completed: strict schema remains compatible with the OpenAI Responses API and gateway TypeScript build.
- Completed: the model has explicit rules for paragraph, numbered list, bullet list, and safety note blocks.

Validation:

- Completed: `pnpm --filter @cav/gateway-api run build` passes.
- Completed: compiled-service contract check confirms `chatTurnResponseFormat()` exposes `formatVersion` and strict `displayBlocks` schema.
- Completed: compiled-service mocked urgent dry-run check confirms payload includes `formatVersion` and `displayBlocks` with a `safety_note` block.
- Deferred to Phase 2/4: real provider smoke and formatting evals for urgent `numbered_list` behavior after the normalizer and eval harness exist.

### Phase 2: Gateway Formatter And Repair Layer

Status: complete on 2026-06-30.

Purpose: make formatting deterministic even when the model output is imperfect.

Tasks:

- Completed: added a formatter and repair layer near `normalizeChatTurnPayload(...)` in `services/gateway-api/src/modules/ai/ai.service.ts`.
- Completed: normalized whitespace inside block text and item strings.
- Completed: stripped Markdown markers such as `**`, `__`, backticks, and heading markers from visible text.
- Completed: stripped accidental list prefixes from list item strings.
- Completed: capped response blocks and list item counts to protect the chat UI.
- Completed: derived fallback blocks from `message` and `intakeQuestions` when `displayBlocks` is missing or invalid.
- Completed: ensured urgent `intakeQuestions` appear once as a `numbered_list` block when urgent intake is active.
- Completed: regenerated `message` from normalized blocks so legacy clients get clean line breaks.
- Completed: added `formattingRepaired` and `formattingWarnings` to the normalized payload so those fields are captured in `ai_events.response_payload`.

Acceptance criteria:

- Completed: numbered list items are normalized without embedded numbering prefixes.
- Completed: triple newlines are removed from fallback `message`.
- Completed: urgent questions are normalized into a single `numbered_list` block when urgent intake is active.
- Completed: malformed or missing `displayBlocks` degrades to clean fallback blocks instead of raw blob rendering.
- Deferred to Phase 4: semantic prompt/eval enforcement for cases where the model asks the wrong clinical or commerce question, because Phase 2 only repairs formatting shape.

Validation:

- Completed: `pnpm --filter @cav/gateway-api run build` passes.
- Completed: VS Code diagnostics report no errors in `services/gateway-api/src/modules/ai/ai.service.ts`.
- Completed: focused compiled-service fixture smoke validates all Phase 0 cases for `formatVersion`, valid `displayBlocks`, block/item caps, no triple newlines, no Markdown markers, and no embedded list prefixes.

### Phase 3: Mobile Block Renderer

Status: complete on 2026-06-30.

Purpose: render the structured contract instead of cleaning a string with regex.

Tasks:

- Completed: extended `_AiChatPayload` in `apps/mobile/lib/src/features/chat/presentation/chat_screen.dart` to parse `formatVersion` and `displayBlocks`.
- Completed: added a compact `_AiMessageBlock` model and `_AiMessageBlockType` enum.
- Completed: added `_AssistantMessageContent` for assistant bubbles.
- Completed: rendered paragraphs with controlled spacing.
- Completed: rendered numbered lists as rows with a fixed-width number label and wrapping item text.
- Completed: rendered bullet lists with a small dot marker and wrapping item text.
- Completed: rendered safety notes with restrained text styling inside the same bubble, not as a nested card.
- Completed: kept `_readableAssistantText(...)` as the fallback for legacy payloads, error messages, and payloads without valid version-1 blocks.

Acceptance criteria:

- Completed: urgent question sets can display as real numbered rows from `numbered_list` blocks.
- Completed: long question text wraps under the item text because list rows use a fixed-width marker column and expanded text column.
- Completed: no extra blank line is inserted before item 1 by the renderer.
- Completed: paragraph-to-list spacing is controlled by block and row padding shared by embedded and full-screen chat.
- Completed: legacy string payloads still render through `_readableAssistantText(...)`.

Validation:

- Completed: `flutter analyze lib/src/features/chat/presentation/chat_screen.dart` passes from `apps/mobile`.
- Completed: VS Code diagnostics report no errors in `apps/mobile/lib/src/features/chat/presentation/chat_screen.dart`.
- Deferred: widget tests are better after extracting the private parser/renderer into a small testable file or adding a dedicated chat-screen harness.
- Deferred: manual mobile smoke with `CAV_AI_CHAT_DRY_RUN=true` and real AI provider should run during staging rollout.

### Phase 4: Prompt Tuning And Formatting Evals

Purpose: reduce formatter repairs and keep future model changes from regressing the chat UX.

Tasks:

- Add representative formatting eval prompts for the current AI concierge flows.
- Check output for valid block types, list item cleanliness, max paragraph length, and no Markdown leakage.
- Include Spanish-first examples because the app usually replies in Spanish.
- Include a generic non-clinical request to ensure the model asks one neutral question without inventing symptoms.
- Include urgent and post-urgent-intake cases to ensure the model switches from asking questions to routing.

Acceptance criteria:

- Formatting evals cover the highest-risk flows.
- Evals fail when output falls back to one giant paragraph.
- Evals fail when list markers are embedded in item text.
- Evals are cheap enough to run during prompt or schema changes.

Validation:

- Run the formatting eval suite before changing the prompt contract.
- Compare repair warning counts before and after prompt changes.

### Phase 5: Observability And Rollout

Status: implementation complete on 2026-06-30; live staging rollout checks pending after deploy.

Purpose: ship safely and measure real-world formatting quality.

Tasks:

- Completed: stored compact formatting metadata in `ai_events.response_payload.formatting`, including `formatVersion`, `hasDisplayBlocks`, `blockCount`, `blockTypes`, `listItemCount`, `messageLength`, `formattingRepaired`, and `formattingWarnings`.
- Completed: added Supabase migration `supabase/migrations/0061_ai_chat_formatting_observability.sql` with security-invoker observability views for recent chat turns, warning counts, and hourly formatting health.
- Completed: mobile support is already in place while keeping legacy `message` fallback rendering.
- Pending deployment: after mobile and gateway are deployed, enable the new gateway schema in staging and inspect real provider events.
- Pending deployment: monitor urgent intake and routing turns for malformed blocks using the SQL queries.
- Pending release policy: keep fallback rendering for at least one release cycle.

Acceptance criteria:

- Pending deployment: staging logs should show valid `displayBlocks` for real chat turns after deploy.
- Completed: formatting repairs are visible in event payloads through both `payload.formattingWarnings` and compact `formatting` metadata.
- Completed: mobile can render both new `displayBlocks` payloads and legacy string payloads.
- Completed locally: service action buttons and handoff panels were not changed by Phase 5.

Validation:

- Completed: `pnpm --filter @cav/gateway-api run build` passes.
- Completed: compiled-service metadata smoke confirms compact formatting metadata fields are produced.
- Completed: `flutter analyze lib/src/features/chat/presentation/chat_screen.dart` passes.
- Pending deployment: run staging smoke with real AI provider.
- Pending deployment: inspect recent `ai_events` formatting metadata through `public.ai_chat_formatting_events`, `public.ai_chat_formatting_warning_counts_24h`, and `public.ai_chat_formatting_hourly_health_24h`.

### Phase 6: Vet App And Human Handoff Follow-Up

Purpose: reuse the formatting foundation where AI or handoff content appears outside the owner concierge chat.

Tasks:

- Decide whether vet-facing AI summaries should use the same block contract.
- If yes, extract the mobile renderer into a shared Flutter file or duplicate a minimal renderer in the vet app.
- Keep human-authored vet chat messages as plain text unless a future feature explicitly supports rich formatting.
- Ensure handoff summaries stay concise and non-diagnostic.

Acceptance criteria:

- Owner AI concierge formatting remains the priority path.
- Vet UI does not accidentally render arbitrary Markdown from users.
- Shared formatting code does not disrupt realtime human chat work.

Validation:

- Run `flutter analyze` for any touched vet files.
- Smoke a routed owner-to-vet consultation after renderer changes.

## Fast Implementation Order

1. Add `formatVersion` and `displayBlocks` to the gateway chat response schema.
2. Add a gateway normalizer that repairs or derives blocks and regenerates the legacy `message` fallback.
3. Parse `displayBlocks` in the mobile `_AiChatPayload` model.
4. Replace assistant bubble text rendering with a custom block renderer.
5. Add focused formatting fixtures or smoke checks.
6. Add observability metadata to `ai_events`.
7. Tune prompts only after the contract and renderer are stable.

## Non-Negotiable Formatting Rules

- Do not depend on Markdown for core clinical chat layout.
- Do not render arbitrary model-provided Markdown in the mobile chat bubble.
- Do not put manual numbering inside list item strings.
- Do not show more than one urgent question set for the same intake turn.
- Do not let formatting changes alter safety rules, entitlement checks, service routing, or human-vet handoff behavior.
- Keep `message` as a fallback until all clients are confirmed to use `displayBlocks`.

## Open Decisions

- Whether `displayBlocks` should include `title` in a later version. Phase 1 should avoid titles to keep bubbles compact.
- Whether `safety_note` should be visually distinct or rendered as a normal paragraph with slightly different color/weight.
- Whether formatting evals should be a pure local validator against saved payloads or an OpenAI-backed staging smoke.
- Whether formatter repair warnings should live only in `ai_events.response_payload` or also be exposed to admin observability UI.

## Done Definition

This roadmap is complete when:

- Real AI chat responses render paragraphs and numbered questions with deterministic spacing in mobile.
- The gateway response has a stable structured display contract.
- Legacy `message` fallback remains clean.
- Formatting issues are covered by fixtures or smoke tests.
- Staging event logs make formatting repairs visible.
- Existing AI routing, entitlement, and handoff flows continue to pass their current validation checks.