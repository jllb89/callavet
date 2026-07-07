# Vet AI Assistant Roadmap

## Goal

Build a world-class clinical productivity assistant for veterinarians inside the vet app. The assistant should help vets ask questions about patients, clients, prior chats, videocalls, handoffs, appointments, care plans, recommendations, and follow-up history without replacing clinical judgment or inventing records.

The first app shell is in place: the vet dashboard now opens a refined assistant-style chat route. This roadmap defines the backend, retrieval, safety, and product work needed before the assistant can answer with real clinical and operational context.

## Product Principles

- Do not hardcode clinical answers, summaries, recommendations, or explanations in the app.
- Generate assistant responses server-side with auditable AI events and model/version metadata.
- Ground every patient/client answer in authorized Call a Vet records, not model memory.
- Show uncertainty when data is missing, stale, contradictory, or outside the vet's permissions.
- Keep the vet in control: the assistant drafts, summarizes, searches, and compares, but does not finalize medical decisions.
- Preserve consult-session chat as a separate workflow from the vet's personal assistant chat.
- Make answers compact, scannable, and professionally formatted: short paragraphs, numbered next steps, bullets, and clear source context.
- Respect current RLS and service-layer boundaries: assigned vets can use assigned/encounter-scoped records, while admin-only or owner-only data must be exposed only through explicit, audited server tools.

## Current App State

- Vet dashboard has the same refined prompt structure as the owner app: gradient, top geometry, bottom composer, placeholder rendering, and assistant prompt mode.
- `/chat/assistant` is reserved for the vet personal assistant surface.
- `/chat/:sessionId` still supports existing consultation chat messages.
- Dashboard and chat use no-transition pages, while chat-to-dashboard uses an explicit fade-out.
- The assistant route currently captures vet prompts locally as UI structure only. Real AI responses are intentionally deferred until the server-side vet assistant exists.

## Current DB Inventory From Migrations

The vet assistant should be built against the current migration-backed data model, not a new parallel record system. The server should load and redact these sources before the model receives context.

### Identity, Vet Profile, And Permissions

- `users`: owner/vet/admin identity, email, full name, phone, role, verification, timezone, country/state, and limited billing profile fields. Vet assistant should use owner identity/contact context only when needed for assigned care workflows.
- `vets`: vet license, country, bio, years of experience, approval state, specialty ids, languages, and search/vector metadata.
- `vet_specialties`: active Spanish equine specialty catalog with descriptions and sort order.
- `vet_availability`: recurring vet availability windows.
- `appointments`: scheduled/confirmed/active/completed/no-show/canceled appointment records linked to user and vet.
- `vet_referrals`: AI/human referral workflow with pet, owner, specialty, assigned vet, appointment, priority, status, and notes.
- `vet_consult_locks`: active chat/video vet locks, mode, expiry, release reason, and lock observability.

### Patient And Owner Clinical Context

- `pets`: patient profile linked to owner, including name, species, sex, age range, weight range, location, breed and conditional breed text, primary activity, discipline, training intensity, terrain, recent observations, known conditions, current treatments/supplements, last vet check, vaccine/deworming status, additional notes, and insurance flag.
- `pet_health_profiles`: one-to-one structured horse health profile with allergies, chronic conditions, current medications, vaccine history, injury history, procedure history, feed profile, insurance details, and emergency contacts.
- `global_pet_health_data`: anonymized/aggregate-like health data with species, breed, sex, age, weight, region, symptoms, diagnosis label, consult date, notes, source type, and linked consultation.

### Consult Timeline And Clinical Artifacts

- `chat_sessions`: owner, vet, pet, product, status, mode (`chat` or `video`), started/ended timestamps, specialty, and priority.
- `messages`: consult chat messages with sender, role, content, embeddings/search, idempotency key, stream order, edit timestamp, deletion/redaction fields, and original redacted content for audited recovery.
- `message_receipts`: delivered/read receipt state by message and user.
- `clinical_encounters`: timeline entity linking session, appointment, pet, owner, vet, video room, open/closed status, and timestamps.
- `consultation_notes`: summary, plan, assessment, diagnosis, follow-up instructions, next follow-up time, severity, embeddings/search, and encounter linkage.
- `care_plans`: short/mid/long-term plan text, AI-created flag, embeddings/search, pet and encounter linkage.
- `care_plan_items`: consult/vaccine/product items, descriptions, price, and fulfillment state.
- `image_cases`: image URLs, labels, findings, diagnosis label, image embeddings/search, pet/session/encounter linkage.
- `encounter_files`: encounter-linked uploaded artifacts with storage path, content type, labels, uploader, pet, and session.

### AI, Handoff, And Structured Drafting

- `ai_feature_flags` and `ai_prompt_versions`: feature gates, active prompt versions, model name, system prompt, user template, and output schema.
- `ai_events`: auditable AI runs linked to actor, pet, encounter, session, referral, note, care plan, prompt version, request/response payloads, provider/model, status, latency, and errors.
- `ai_drafts`: reviewable triage, referral, note, and care-plan drafts with review state, payload, reviewer, and linked AI event.
- `ai_handoffs`: pre-consult handoff summary with urgency, reported signs, red flags, answered/unanswered questions, recommended first checks, source payload, session, pet, vet, and specialty.
- AI observability views: `ai_job_runs`, `ai_chat_formatting_events`, `ai_chat_formatting_warning_counts_24h`, `ai_chat_formatting_hourly_health_24h`, `ai_handoff_session_observability`, and `ai_handoff_generation_health_24h`.

### Video, LiveKit, And Post-Call State

- `video_session_lifecycle`: LiveKit room identifiers, lifecycle status, owner/vet join timestamps, both-joined timestamp, last-left/finished timestamps, forced end, entitlement finalization/release, egress/recording hooks, end actor, end reason, rejoin eligibility, and post-call AI message payload.
- `livekit_video_events`: raw LiveKit room/participant lifecycle events with room/session identifiers, participant identity, payload, receive/process timestamps, and processing errors.
- Video observability views: `video_lifecycle_observability`, `video_lifecycle_health_24h`, and `recent_video_event_observability`.

### Feedback, Ratings, And Quality Signals

- `ratings`: session/vet/user score and comment.
- `consult_surveys`: owner post-consult survey workflow with status, prompt/defer/complete timestamps, vet assistance score, app service score, open feedback, source, and metadata.
- Survey observability views: `consult_survey_pending_observability`, `consult_survey_completion_health_24h`, and `consult_survey_scores_rolling_30d`.
- Important permission note: current `consult_surveys` RLS is owner/admin-scoped. Vet assistant access to survey details must be through a vetted server tool that exposes only allowed per-vet aggregates or explicitly approved feedback fields.

### Knowledge, Search, And Retrieval Targets

- `kb_articles` and `kb_items`: internal knowledge base content, language/species/tags/status/version, embeddings, and search vectors.
- `vector_targets`: active vector-search target registry for `kb_articles`, `messages`, `consultation_notes`, `products`, `services`, `pets`, and `vets`.
- `products`, `services`, `service_providers`, `vet_care_centers`, and `vet_clinic_affiliations`: operational directory/catalog data that may support recommendations, referrals, or care-plan item context.

### Commercial And Entitlement Data

- `subscription_plans`, `user_subscriptions`, `subscription_usage`, `entitlement_consumptions`, `overage_items`, `overage_purchases`, `overage_credits`, `payments`, and `invoices` exist for service access and billing operations.
- Vet assistant should not expose raw payment, invoice, tax, or subscription internals by default. It may use server-approved summaries such as whether a consult/session is active, paid, pending payment, or eligible for rejoin/handoff.

## Roadmap

### 1. Vet Assistant Backend Orchestrator

Add a dedicated authenticated endpoint such as `POST /vets/me/assistant/turn`.

Responsibilities:

- Authenticate the vet through Supabase JWT.
- Load vet profile, approval status, specialties, active queue, and permitted records.
- Accept the latest prompt plus bounded prior assistant turns.
- Call the AI provider server-side using strict JSON output schemas.
- Execute only allowlisted tools; disable arbitrary tool names.
- Persist each turn in `ai_events` with feature key `vet.assistant_turn`.
- Return a normalized UI payload with `message`, `displayBlocks`, `sourceCards`, `actions`, and trace metadata.

Acceptance criteria:

- Endpoint rejects unauthenticated and unapproved vet access.
- Endpoint never exposes records outside the vet's permission scope.
- Responses are generated by AI, not hardcoded app copy.
- Every turn is auditable by vet id, prompt hash, tool calls, model, latency, and outcome.

### 2. Permissioned Context Loader

Build a server-side context layer that answers: what can this vet see right now?

Context sources:

- Vet profile, approval status, specialties, availability, active queue, active locks, and assigned appointment/referral state.
- Active and historical assigned `chat_sessions`, including mode, status, specialty, priority, entitlement/session state, and timestamps.
- Session `messages`, `message_receipts`, redaction/deletion state, and bounded transcript summaries.
- Patient profile from `pets` and `pet_health_profiles`, plus owner profile fields needed for assigned clinical care.
- `clinical_encounters`, consultation notes, care plans/items, image cases, and encounter files for patient timeline answers.
- `ai_handoffs`, `ai_events`, and `ai_drafts` for pre-consult summaries, generated recommendations, and reviewable draft provenance.
- Video lifecycle and LiveKit event summaries from `video_session_lifecycle` and `livekit_video_events`.
- Ratings/survey quality signals only through explicit server-side permission rules; raw `consult_surveys` rows are owner/admin-scoped today.
- Knowledge-base and vector targets for general reference material and similarity search.

Acceptance criteria:

- The assistant can answer questions about active assigned consults.
- The assistant can search past assigned consults by patient, client, symptom, date, or specialty.
- The context loader returns source ids and timestamps for every retrieved object.
- Unauthorized data is excluded before the model receives context.

### 3. Retrieval And Search Tools

Give the assistant a small, explicit tool set.

Initial tools:

- `get_vet_workbench`: Return vet profile, active queue, active locks, upcoming appointments, and relevant handoff readiness.
- `search_patients`: Find permitted patients by name, owner, species, or recent symptom text.
- `get_patient_timeline`: Return a chronological patient/client consult timeline.
- `get_consult_summary`: Load one consult's handoff, transcript/messages, video lifecycle, and outcome.
- `search_consults`: Find prior consults by symptom, specialty, urgency, or date range.
- `compare_cases`: Retrieve similar prior cases from the vet's permitted history.
- `get_video_call_context`: Return room lifecycle, join/leave timing, end reason, rejoin window, post-call payload, and LiveKit event summary.
- `get_patient_files`: Return encounter files and image case summaries with allowed file labels and source metadata.
- `search_knowledge_base`: Retrieve published KB/reference content and vector-target-backed snippets.
- `get_quality_signals`: Return allowed ratings/survey aggregates and approved feedback snippets for the vet's own consults.
- `draft_follow_up`: Draft a follow-up note or client message from grounded context.

Deferred tools:

- `create_care_plan_draft`
- `create_note_draft`
- `suggest_diagnostics_checklist`
- `schedule_follow_up`
- `handoff_to_support`

Acceptance criteria:

- Tool inputs are strict JSON schemas.
- Tools return compact summaries plus source references, not raw unbounded records.
- The model cannot call database, HTTP, or arbitrary code tools.

### 4. Assistant Response Contract

Define a response format shared by backend and Flutter.

Suggested payload:

```json
{
  "formatVersion": 1,
  "message": "string",
  "displayBlocks": [
    { "type": "paragraph", "text": "string", "items": [] },
    { "type": "numbered_list", "text": null, "items": ["string"] },
    { "type": "bullet_list", "text": null, "items": ["string"] },
    { "type": "safety_note", "text": "string", "items": [] }
  ],
  "sourceCards": [
    {
      "type": "consult",
      "id": "uuid",
      "title": "string",
      "subtitle": "string",
      "timestamp": "iso8601"
    }
  ],
  "actions": [
    { "type": "open_consult", "label": "string", "sessionId": "uuid" }
  ]
}
```

Acceptance criteria:

- Flutter renders blocks without markdown guessing.
- Source cards can deep-link to consult, patient, video handoff, or appointment views.
- Actions are allowlisted and validated server-side before execution.

### 5. Vet App AI Transport

Replace the temporary local-only assistant shell with real server turns.

Needed behavior:

- Send prompts to `POST /vets/me/assistant/turn` with Supabase bearer auth.
- Include bounded prior assistant turns for continuity.
- Render loading/thinking state in the existing composer.
- Render assistant messages with the structured block renderer already used by vet consult chat.
- Render source cards below assistant answers.
- Keep local optimistic vet messages, then reconcile with server response.
- Handle expired session, gateway timeout, model failure, permission denial, and empty context.

Acceptance criteria:

- First prompt from dashboard is sent automatically after route entry.
- Back to dashboard fades out before route change.
- No assistant answer is generated client-side.
- A failed AI turn leaves the vet's typed prompt visible and retryable.

### 6. Patient And Consult Drill-Down UX

The assistant should become a command surface for clinical navigation.

Views and actions:

- Open active consult.
- Open prior consult summary.
- Open AI handoff.
- Open patient timeline.
- Open video session details.
- Draft follow-up message.
- Draft internal note.
- Copy concise summary for the vet's working notes.

Acceptance criteria:

- Source cards feel native, dense, and tappable.
- The assistant never traps the vet; every answer can lead to the underlying record.
- Actions require explicit vet confirmation before mutating data.

### 7. Safety And Clinical Guardrails

Guardrails:

- The assistant may summarize records, retrieve context, compare prior consults, and draft documentation.
- The assistant must not claim certainty beyond retrieved records.
- The assistant must not invent patient history, medication, lab values, exam findings, or owner statements.
- The assistant must distinguish record-derived facts from general clinical considerations.
- Recommendations must be phrased as decision support for a licensed vet, not as autonomous diagnosis.
- Emergency or high-risk answers should include a clear escalation/safety note.

Acceptance criteria:

- Red-team prompts cannot extract unauthorized client/patient data.
- Model responses cite source cards when using patient-specific facts.
- Missing data produces explicit uncertainty instead of fabricated details.

### 8. Memory And Personalization

Add opt-in assistant memory after the core assistant is reliable.

Memory candidates:

- Vet's preferred answer style.
- Common summary format.
- Frequently used follow-up phrasing.
- Specialty-specific defaults.

Rules:

- Do not store raw clinical facts as personal memory.
- Store preferences separately from patient records.
- Let the vet inspect, edit, and disable memory.

### 9. Observability, Evals, And QA

Required eval suites:

- Active consult lookup.
- Past patient timeline retrieval.
- Similar-case search.
- Missing-record uncertainty.
- Permission-boundary refusal.
- Post-video summary generation.
- Follow-up draft quality.
- Spanish clinical formatting and tone.

Operational metrics:

- Turn latency.
- Tool-call success/failure.
- Retrieval hit count.
- Empty-context rate.
- Permission-denied rate.
- Retry rate.
- Vet action click-through.
- Vet thumbs-up/down feedback.

### 10. Launch Sequence

1. Ship UI shell and route separation.
2. Add backend `vet.assistant_turn` endpoint with no mutating tools.
3. Add permissioned context loader for active consults.
4. Add consult/patient search tools.
5. Wire Flutter assistant transport and structured rendering.
6. Add source cards and deep links.
7. Add follow-up/note drafting as explicit draft-only tools.
8. Run red-team and permission evals.
9. Pilot with staging vets.
10. Promote to production behind a feature flag.

## Open Decisions

- Whether the assistant should support voice dictation in the first release.
- Whether patient timelines should be a separate screen or an assistant source-card expansion.
- Whether assistant conversations should persist across app sessions or remain ephemeral until backend memory is ready.
- Which source types should be visible to support/admin users versus assigned vets only.