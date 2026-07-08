import { BadGatewayException, BadRequestException, ForbiddenException, GatewayTimeoutException, Injectable, ServiceUnavailableException } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { ValidatorService } from '../config/validator.service';
import { VectorTargetService } from '../config/vector-target.service';
import { EntitlementKind, EntitlementService } from '../subscriptions/entitlement.service';
import { AppointmentSchedulingService } from '../appointments/appointment-scheduling.service';

type AiDraftType = 'triage' | 'referral' | 'note' | 'care_plan';
type AiReviewStatus = 'reviewed' | 'accepted' | 'rejected' | 'superseded';
type AiApiMode = 'responses' | 'chat_completions';
type AiReasoningEffort = 'none' | 'low' | 'medium' | 'high' | 'xhigh';
type AiChatNextStep = 'interview' | 'recommendation' | 'activation' | 'handoff' | 'payment';

type AiProviderConfig = {
  provider: string;
  apiKey: string;
  baseUrl: string;
  model: string;
  timeoutMs: number;
  apiMode: AiApiMode;
  reasoningEffort?: AiReasoningEffort;
};

type AiRunInput = {
  petId?: string;
  encounterId?: string;
  sessionId?: string;
  symptoms?: string;
  question?: string;
  context?: Record<string, any>;
  dryRun?: boolean;
};

type AiEmbeddingInput = {
  target?: string;
  ids?: string[];
  limit?: number;
  dryRun?: boolean;
  persist?: boolean;
  regenerate?: boolean;
};

type AiChatRole = 'user' | 'assistant' | 'ai';

type AiChatMessageInput = {
  role?: AiChatRole;
  content?: string;
  metadata?: {
    nextStep?: string;
    urgency?: string;
    intakeQuestions?: string[];
    recommendedService?: string | null;
    caseSummary?: string | null;
    handoffSummary?: string | null;
  };
};

type AiChatTurnInput = {
  conversationId?: string;
  petId?: string;
  sessionId?: string;
  message?: string;
  messages?: AiChatMessageInput[];
  dryRun?: boolean;
};

type AiSessionHandoffInput = {
  sessionId?: string;
  sourceAiEventId?: string;
  aiContext?: Record<string, any> | null;
  dryRun?: boolean;
};

type AiVideoPostCallInput = {
  sessionId?: string;
  endState?: Record<string, any> | null;
  dryRun?: boolean;
};

type AiSessionHandoffContext = {
  actorUserId: string;
  session: Record<string, any>;
  aiContext: Record<string, any> | null;
  sourceAiEvents: Array<Record<string, any>>;
};

type AiVideoPostCallContext = {
  actorUserId: string;
  session: Record<string, any>;
  lifecycle: Record<string, any> | null;
  handoff: Record<string, any> | null;
  endState: Record<string, any> | null;
};

type AiChatToolName = 'recommend_specialty' | 'find_vets' | 'check_service_access' | 'get_available_slots' | 'schedule_video' | 'schedule_chat';

type AiChatToolCall = {
  type: 'function_call';
  call_id: string;
  name: AiChatToolName | string;
  arguments: string;
};

type AiChatDisplayBlockType = 'paragraph' | 'numbered_list' | 'bullet_list' | 'safety_note';

type AiChatDisplayBlock = {
  type: AiChatDisplayBlockType;
  text: string | null;
  items: string[];
};

type AiChatTurnContext = {
  actorUserId: string;
  petId: string | null;
  sessionId: string | null;
  conversationId: string | null;
  user: Record<string, any> | null;
  pets: any[];
  subscription: Record<string, any> | null;
  recentConversations: any[];
};

type AiChatTurnState = {
  urgentIntakeAlreadyAsked: boolean;
  afterUrgentIntakeAnswer: boolean;
  latestUserLikelyAnsweringIntake: boolean;
  clinicalSignal: boolean;
  caseDetailSignal: boolean;
  explicitCareRequest: boolean;
  wantsScheduling: boolean;
  schedulingStage: string | null;
  schedulingRange: string | null;
  schedulingDaypart: string | null;
};

type PromptVersion = {
  id: string;
  prompt_key: string;
  version: number;
  model: string | null;
  system_prompt: string;
  user_template: string;
  output_schema: Record<string, any>;
};

type AiContext = {
  actorUserId: string;
  petId: string | null;
  encounterId: string | null;
  sessionId: string | null;
  pet: any;
  encounter: any;
  session: any;
  healthProfile: any;
  recentEncounters: any[];
  notes: any[];
  imageCases: any[];
  carePlans: any[];
  kbArticles: any[];
  specialties: any[];
  input: Record<string, any>;
};

@Injectable()
export class AiService {
  constructor(
    private readonly db: DbService,
    private readonly rc: RequestContext,
    private readonly validator: ValidatorService,
    private readonly vectorTargets: VectorTargetService,
    private readonly entitlements: EntitlementService,
    private readonly appointmentScheduling: AppointmentSchedulingService,
  ) {}

  private roadmapLog(event: string, metadata: Record<string, any> = {}) {
    console.log(JSON.stringify({
      scope: 'video_handoff_roadmap',
      component: 'ai',
      event,
      at: new Date().toISOString(),
      ...metadata,
    }));
  }

  private providerConfig(prompt?: PromptVersion, dryRun = false): AiProviderConfig {
    const provider = dryRun ? 'dry_run' : (process.env.AI_PROVIDER || 'openai');
    const apiKey = process.env.AI_PROVIDER_API_KEY || process.env.OPENAI_API_KEY || '';
    const baseUrl = (process.env.AI_PROVIDER_BASE_URL || 'https://api.openai.com/v1').replace(/\/$/, '');
    const model = prompt?.model || process.env.AI_MODEL || 'gpt-5.4-mini';
    const timeoutMs = Math.min(Math.max(Number(process.env.AI_REQUEST_TIMEOUT_MS || '30000') || 30000, 5000), 120000);
    const requestedApiMode = String(process.env.AI_API_MODE || '').trim().toLowerCase();
    const apiMode: AiApiMode = requestedApiMode === 'chat_completions'
      ? 'chat_completions'
      : requestedApiMode === 'responses'
        ? 'responses'
        : provider === 'openai'
          ? 'responses'
          : 'chat_completions';
    const requestedReasoningEffort = String(process.env.AI_REASONING_EFFORT || '').trim().toLowerCase();
    const reasoningEffort = ['none', 'low', 'medium', 'high', 'xhigh'].includes(requestedReasoningEffort)
      ? requestedReasoningEffort as AiReasoningEffort
      : undefined;
    return { provider, apiKey, baseUrl, model, timeoutMs, apiMode, reasoningEffort };
  }

  private embeddingProviderConfig(dryRun = false) {
    const base = this.providerConfig(undefined, dryRun);
    return { ...base, model: process.env.AI_EMBEDDING_MODEL || 'text-embedding-3-small' };
  }

  private normalizeOptionalUuid(value: string | undefined, name: string) {
    const trimmed = String(value || '').trim();
    if (!trimmed) return null;
    this.validator.validateUUID(trimmed, name);
    return trimmed;
  }

  private normalizeOptionalToolUuid(value: unknown, name: string) {
    const trimmed = String(value || '').trim();
    if (!trimmed || trimmed.toLowerCase() === 'null') return null;
    try {
      this.validator.validateUUID(trimmed, name);
      return trimmed;
    } catch {
      return null;
    }
  }

  private async featureEnabled(featureKey: string) {
    try {
      const { rows } = await this.db.query<{ enabled: boolean }>(
        `select enabled from ai_feature_flags where key = $1 limit 1`,
        [featureKey]
      );
      return rows[0]?.enabled === true;
    } catch {
      return false;
    }
  }

  private async loadPrompt(promptKey: string) {
    const { rows } = await this.db.query<PromptVersion>(
      `select id, prompt_key, version, model, system_prompt, user_template, output_schema
         from ai_prompt_versions
        where prompt_key = $1
          and is_active = true
        order by version desc
        limit 1`,
      [promptKey]
    );
    if (!rows[0]) throw new ServiceUnavailableException('ai_prompt_not_configured');
    return rows[0];
  }

  private renderPrompt(template: string, context: AiContext) {
    return template.replace('{{context}}', JSON.stringify(context));
  }

  private validateSqlIdentifier(value: string, name: string) {
    if (!/^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)?$/i.test(value)) {
      throw new BadRequestException(`${name}_invalid`);
    }
    return value;
  }

  private normalizeEmbedding(arr: any, dim: number): number[] {
    const src = Array.isArray(arr) ? arr : [];
    const out = new Array<number>(dim);
    const n = Math.min(src.length, dim);
    for (let i = 0; i < n; i++) {
      const value = Number(src[i]);
      out[i] = Number.isFinite(value) ? value : 0;
    }
    for (let i = n; i < dim; i++) out[i] = 0;
    return out;
  }

  private dryRunEmbedding(text: string, dim: number) {
    const vector = new Array<number>(dim).fill(0);
    const source = text || 'empty';
    for (let i = 0; i < source.length; i++) {
      vector[i % dim] += ((source.charCodeAt(i) % 97) + 1) / 1000;
    }
    const norm = Math.sqrt(vector.reduce((sum, value) => sum + value * value, 0)) || 1;
    return vector.map((value) => Number((value / norm).toFixed(8)));
  }

  private async buildContext(input: AiRunInput): Promise<AiContext> {
    const actorUserId = this.rc.requireUuidUserId();
    const requestedPetId = this.normalizeOptionalUuid(input.petId, 'petId');
    const requestedEncounterId = this.normalizeOptionalUuid(input.encounterId, 'encounterId');
    const requestedSessionId = this.normalizeOptionalUuid(input.sessionId, 'sessionId');

    if (!requestedPetId && !requestedEncounterId && !requestedSessionId) {
      throw new BadRequestException('petId_or_encounterId_or_sessionId_required');
    }

    return this.db.runInTx(async (q) => {
      let encounter: any = null;
      let session: any = null;
      let petId = requestedPetId;

      if (requestedEncounterId) {
        const { rows } = await q<{ data: any }>(
          `select to_jsonb(ce) as data
             from clinical_encounters ce
            where ce.id = $1::uuid
              and (ce.user_id = auth.uid() or ce.vet_id = auth.uid() or is_admin())
            limit 1`,
          [requestedEncounterId]
        );
        encounter = rows[0]?.data || null;
        if (!encounter) throw new BadRequestException('encounter_not_found');
        petId = petId || encounter.pet_id || null;
        if (!session && encounter.session_id) {
          const sessionRows = await q<{ data: any }>(`select to_jsonb(s) as data from chat_sessions s where s.id = $1::uuid limit 1`, [encounter.session_id]);
          session = sessionRows.rows[0]?.data || null;
        }
      }

      if (requestedSessionId) {
        const { rows } = await q<{ data: any }>(
          `select to_jsonb(s) as data
             from chat_sessions s
            where s.id = $1::uuid
              and (s.user_id = auth.uid() or s.vet_id = auth.uid() or is_admin())
            limit 1`,
          [requestedSessionId]
        );
        session = rows[0]?.data || null;
        if (!session) throw new BadRequestException('session_not_found');
        petId = petId || session.pet_id || null;
      }

      if (!petId) throw new BadRequestException('pet_id_missing');

      const { rows: petRows } = await q<{ data: any }>(
        `select to_jsonb(p) as data
           from pets p
          where p.id = $1::uuid
            and (
              p.user_id = auth.uid()
              or is_admin()
              or exists (select 1 from chat_sessions s where s.pet_id = p.id and s.vet_id = auth.uid())
              or exists (select 1 from clinical_encounters ce where ce.pet_id = p.id and ce.vet_id = auth.uid())
            )
          limit 1`,
        [petId]
      );
      const pet = petRows[0]?.data || null;
      if (!pet) throw new BadRequestException('pet_not_found_for_actor');

      const [healthProfile, recentEncounters, notes, imageCases, carePlans, specialties, kbArticles] = await Promise.all([
        q<{ data: any }>(`select to_jsonb(h) as data from pet_health_profiles h where h.pet_id = $1::uuid limit 1`, [petId]),
        q<any>(
          `select id, session_id, appointment_id, status, started_at, ended_at, created_at
             from clinical_encounters
            where pet_id = $1::uuid
            order by coalesce(started_at, created_at) desc
            limit 5`,
          [petId]
        ),
        q<any>(
          `select id, encounter_id, session_id, summary_text, plan_summary, assessment_text,
                  diagnosis_text, follow_up_instructions, severity, created_at
             from consultation_notes
            where pet_id = $1::uuid
            order by created_at desc
            limit 5`,
          [petId]
        ),
        q<any>(
          `select id, encounter_id, session_id, labels, findings, diagnosis_label, created_at
             from image_cases
            where pet_id = $1::uuid
            order by created_at desc
            limit 5`,
          [petId]
        ),
        q<any>(
          `select id, encounter_id, created_by_ai, short_term, mid_term, long_term, created_at
             from care_plans
            where pet_id = $1::uuid
            order by created_at desc
            limit 5`,
          [petId]
        ),
        q<any>(`select id, name, description from vet_specialties order by lower(name) asc`),
        input.symptoms?.trim()
          ? q<any>(
              `select id, title, tags, species, updated_at
                 from kb_articles
                where status = 'published'
                  and search_tsv @@ websearch_to_tsquery('simple', $1)
                order by updated_at desc
                limit 5`,
              [input.symptoms.trim()]
            )
          : Promise.resolve({ rows: [] as any[] }),
      ]);

      return {
        actorUserId,
        petId,
        encounterId: requestedEncounterId || encounter?.id || null,
        sessionId: requestedSessionId || session?.id || encounter?.session_id || null,
        pet,
        encounter,
        session,
        healthProfile: healthProfile.rows[0]?.data || null,
        recentEncounters: recentEncounters.rows,
        notes: notes.rows,
        imageCases: imageCases.rows,
        carePlans: carePlans.rows,
        kbArticles: kbArticles.rows,
        specialties: specialties.rows,
        input: {
          symptoms: input.symptoms || null,
          question: input.question || null,
          ...(input.context || {}),
        },
      };
    });
  }

  private dryRunPayload(draftType: AiDraftType, context: AiContext) {
    const petName = context.pet?.name || 'this horse';
    switch (draftType) {
      case 'triage':
        return {
          summary: `Review ${petName} for reported symptoms and recent clinical history.`,
          redFlags: ['severe pain', 'difficulty breathing', 'inability to stand', 'rapid worsening'],
          recommendedSpecialty: context.specialties[0]?.name || 'General equine medicine',
          priority: 'routine',
          questions: ['When did symptoms begin?', 'Any fever, colic signs, or lameness?', 'Any recent medication changes?'],
          rationale: 'Dry-run draft generated from available pet and encounter context for workflow validation.',
        };
      case 'referral':
        return {
          specialtyName: context.specialties[0]?.name || 'General equine medicine',
          specialtyId: context.specialties[0]?.id || null,
          priority: 'routine',
          rationale: 'Dry-run referral recommendation based on available specialty list and context.',
          confidence: 0.5,
        };
      case 'note':
        return {
          summaryText: `Draft summary for ${petName}.`,
          assessmentText: 'Clinician review required. AI draft is based on available structured context only.',
          diagnosisText: 'No final diagnosis. Pending clinician assessment.',
          planSummary: 'Continue monitoring and follow clinician recommendations.',
          followUpInstructions: 'Escalate if red flags appear or symptoms worsen.',
          severity: 'low',
        };
      case 'care_plan':
        return {
          shortTerm: 'Monitor symptoms, hydration, appetite, and comfort closely.',
          midTerm: 'Schedule clinician follow-up if symptoms persist or functional status changes.',
          longTerm: 'Review preventive care, workload, nutrition, and recurrence risks with the vet.',
          items: [{ type: 'consult', description: 'Clinician review of AI draft before any owner-facing plan is published.' }],
        };
    }
  }

  private strictOutputSchema(schema: Record<string, any>) {
    const normalize = (node: any): any => {
      if (!node || typeof node !== 'object' || Array.isArray(node)) return node;
      const out: Record<string, any> = { ...node };
      if (out.properties && typeof out.properties === 'object' && !Array.isArray(out.properties)) {
        out.type = 'object';
        out.properties = Object.fromEntries(Object.entries(out.properties).map(([key, value]) => [key, normalize(value)]));
        out.required = Object.keys(out.properties);
        out.additionalProperties = false;
      }
      if (out.items) out.items = normalize(out.items);
      if (Array.isArray(out.anyOf)) out.anyOf = out.anyOf.map(normalize);
      if (out.$defs && typeof out.$defs === 'object') {
        out.$defs = Object.fromEntries(Object.entries(out.$defs).map(([key, value]) => [key, normalize(value)]));
      }
      return out;
    };
    return normalize(schema);
  }

  private responseFormat(prompt: PromptVersion) {
    const schema = prompt.output_schema && Object.keys(prompt.output_schema).length > 0
      ? prompt.output_schema
      : { type: 'object', properties: { result: { type: 'string' } }, required: ['result'] };
    return {
      type: 'json_schema',
      name: (prompt.prompt_key || 'ai_response').replace(/[^a-zA-Z0-9_-]/g, '_').slice(0, 64),
      strict: true,
      schema: this.strictOutputSchema(schema),
    };
  }

  private chatTurnResponseFormat() {
    return {
      type: 'json_schema',
      name: 'ai_chat_turn',
      strict: true,
      schema: {
        type: 'object',
        additionalProperties: false,
        required: [
          'message',
          'formatVersion',
          'displayBlocks',
          'nextStep',
          'urgency',
          'recommendedService',
          'actionLabel',
          'safetyEscalation',
          'intakeQuestions',
          'caseSummary',
          'handoffSummary',
          'routingRationale',
          'commerceRecommendation',
        ],
        properties: {
          message: { type: 'string', description: 'Plain-text fallback for legacy clients, composed from the same content as displayBlocks.' },
          formatVersion: { type: 'integer', enum: [1], description: 'Version of the structured chat display contract.' },
          nextStep: { type: 'string', enum: ['interview', 'recommendation', 'activation', 'handoff', 'payment'], description: 'Current interaction state. interview means the user should answer the message; recommendation/payment means the client may show action chips.' },
          displayBlocks: {
            type: 'array',
            description: 'Structured user-visible response blocks. New clients render this instead of parsing message text.',
            minItems: 1,
            maxItems: 6,
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['type', 'text', 'items'],
              properties: {
                type: { type: 'string', enum: ['paragraph', 'numbered_list', 'bullet_list', 'safety_note'] },
                text: { type: ['string', 'null'], description: 'Block text for paragraph and safety_note blocks; null for list blocks.' },
                items: {
                  type: 'array',
                  description: 'List items for numbered_list and bullet_list blocks; empty for paragraph and safety_note blocks.',
                  minItems: 0,
                  maxItems: 5,
                  items: { type: 'string' },
                },
              },
            },
          },
          urgency: { type: 'string', enum: ['routine', 'urgent', 'emergency'] },
          recommendedService: { type: ['string', 'null'], enum: ['chat', 'video', 'scheduled_video', 'scheduled_chat', null] },
          actionLabel: { type: ['string', 'null'] },
          safetyEscalation: { type: 'boolean' },
          intakeQuestions: { type: 'array', items: { type: 'string' }, minItems: 0, maxItems: 3 },
          caseSummary: { type: ['string', 'null'], description: 'Concise non-diagnostic summary of the user concern, or null if not enough case detail.' },
          handoffSummary: { type: ['string', 'null'], description: 'Concise handoff context for the human veterinarian, not a diagnosis.' },
          routingRationale: { type: ['string', 'null'], description: 'Brief reason for specialty/service routing, or null while gathering context.' },
          commerceRecommendation: { type: ['string', 'null'], enum: ['included', 'one_off', 'upgrade_plan', 'ask_more', 'none', null] },
        },
      },
    };
  }

  private sessionHandoffResponseFormat() {
    return {
      type: 'json_schema',
      name: 'ai_session_handoff',
      strict: true,
      schema: this.strictOutputSchema({
        type: 'object',
        additionalProperties: false,
        required: [
          'urgency',
          'summaryText',
          'reportedSigns',
          'redFlags',
          'questionsAnswered',
          'questionsUnanswered',
          'recommendedFirstChecks',
        ],
        properties: {
          urgency: { type: 'string', enum: ['routine', 'urgent', 'emergency'] },
          summaryText: { type: 'string', description: 'Concise factual handoff for a veterinarian. Not a diagnosis.' },
          reportedSigns: { type: 'array', minItems: 0, maxItems: 12, items: { type: 'string' } },
          redFlags: { type: 'array', minItems: 0, maxItems: 8, items: { type: 'string' } },
          questionsAnswered: {
            type: 'array',
            minItems: 0,
            maxItems: 12,
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['question', 'answer'],
              properties: {
                question: { type: 'string' },
                answer: { type: 'string' },
              },
            },
          },
          questionsUnanswered: { type: 'array', minItems: 0, maxItems: 10, items: { type: 'string' } },
          recommendedFirstChecks: { type: 'array', minItems: 0, maxItems: 8, items: { type: 'string' } },
        },
      }),
    };
  }

  private sessionHandoffInstructions() {
    return [
      'You create a veterinarian-facing handoff for an equine consult from owner AI chat context.',
      'Return Spanish unless the owner conversation is clearly in another language.',
      'Use only facts present in the provided context. Do not invent symptoms, timing, medications, vitals, exam findings, diagnoses, or treatments.',
      'Never diagnose, prescribe, recommend medication doses, or imply the AI has examined the animal.',
      'Write for the human veterinarian, not the owner. recommendedFirstChecks must be clinician-facing checks to confirm, not instructions for owner treatment.',
      'If information is missing, put it in questionsUnanswered instead of filling it in.',
      'Keep summaryText concise, factual, non-diagnostic, and useful before a chat or video consult.',
    ].join('\n');
  }

  private videoPostCallResponseFormat() {
    return {
      type: 'json_schema',
      name: 'ai_video_post_call_message',
      strict: true,
      schema: this.strictOutputSchema({
        type: 'object',
        additionalProperties: false,
        required: ['message', 'suggestedAction', 'rejoinRecommended'],
        properties: {
          message: { type: 'string', description: 'Short owner-facing post-call message.' },
          suggestedAction: { type: 'string', enum: ['return_to_chat', 'rejoin_call', 'wait_for_vet', 'done'] },
          rejoinRecommended: { type: 'boolean' },
        },
      }),
    };
  }

  private videoPostCallInstructions() {
    return [
      'You write a short owner-facing post-video-call message for Call a Vet.',
      'Reply in Spanish unless the owner context is clearly in another language.',
      'Use only the provided session, handoff, and call-end state. Do not invent what the veterinarian said or did.',
      'Never diagnose, prescribe medication, recommend medication doses, or create clinical findings.',
      'If rejoinEligible is true, explain that the owner can rejoin or continue in chat. If not, guide them back to chat for follow-up.',
      'Keep message concise, calm, and practical. Do not use headings, markdown, or lists.',
    ].join('\n');
  }

  private normalizeVideoPostCallPayload(payload: any, context: AiVideoPostCallContext) {
    const message = String(payload?.message || '').trim().slice(0, 700);
    if (!message) throw new BadGatewayException('ai_video_post_call_message_required');
    const action = String(payload?.suggestedAction || '').trim();
    const suggestedAction = ['return_to_chat', 'rejoin_call', 'wait_for_vet', 'done'].includes(action)
      ? action
      : context.endState?.rejoinEligible === true ? 'rejoin_call' : 'return_to_chat';
    return {
      message,
      suggestedAction,
      rejoinRecommended: payload?.rejoinRecommended === true || suggestedAction === 'rejoin_call',
    };
  }

  private async buildVideoPostCallContext(actorUserId: string, sessionId: string, endState: Record<string, any> | null): Promise<AiVideoPostCallContext> {
    return this.db.runInTx(async (q) => {
      const { rows: sessionRows } = await q<any>(
        `select s.id::text as session_id,
                s.user_id::text,
                s.vet_id::text,
                s.pet_id::text,
                s.specialty_id::text,
                s.priority,
                s.status,
                s.mode,
                s.started_at,
                s.ended_at,
                p.name as pet_name,
                vu.full_name as vet_name,
                vs.name as specialty_name
           from chat_sessions s
      left join pets p on p.id = s.pet_id
      left join users vu on vu.id = s.vet_id
      left join vet_specialties vs on vs.id = s.specialty_id
          where s.id = $1::uuid
            and s.mode = 'video'
            and (s.user_id = auth.uid() or s.vet_id = auth.uid() or is_admin())
          limit 1`,
        [sessionId]
      );
      const session = sessionRows[0];
      if (!session) throw new BadRequestException('video_session_not_found_for_post_call');
      const { rows: lifecycleRows } = await q<any>(
        `select status,
                room_name,
                room_finished_at,
                first_both_joined_at,
                end_actor_role,
                end_actor_user_id::text,
                coalesce(end_reason, safety_reason) as end_reason,
                rejoin_eligible_until
           from video_session_lifecycle
          where session_id = $1::uuid
          limit 1`,
        [sessionId]
      );
      const { rows: handoffRows } = await q<any>(
        `select urgency,
                summary_text,
                reported_signs,
                red_flags,
                questions_answered,
                questions_unanswered,
                recommended_first_checks
           from ai_handoffs
          where session_id = $1::uuid
          order by created_at desc
          limit 1`,
        [sessionId]
      );
      return {
        actorUserId,
        session,
        lifecycle: lifecycleRows[0] || null,
        handoff: handoffRows[0] || null,
        endState: endState || null,
      };
    });
  }

  private async callVideoPostCallProvider(context: AiVideoPostCallContext, dryRun = false) {
    const cfg = this.providerConfig(undefined, dryRun);
    if (dryRun) {
      return {
        provider: cfg.provider,
        model: cfg.model,
        responseId: null,
        payload: {
          message: 'Mensaje AI de prueba para continuar el seguimiento de la videollamada.',
          suggestedAction: context.endState?.rejoinEligible === true ? 'rejoin_call' : 'return_to_chat',
          rejoinRecommended: context.endState?.rejoinEligible === true,
        },
      };
    }
    if (!cfg.apiKey) throw new ServiceUnavailableException('ai_provider_not_configured');
    if (cfg.apiMode !== 'responses') throw new ServiceUnavailableException('ai_video_post_call_requires_responses_api');
    const body: Record<string, any> = {
      model: cfg.model,
      store: false,
      instructions: this.videoPostCallInstructions(),
      input: [{ role: 'user', content: JSON.stringify(context) }],
      text: { format: this.videoPostCallResponseFormat() },
    };
    if (cfg.reasoningEffort) body.reasoning = { effort: cfg.reasoningEffort };
    const data = await this.postProviderJson(cfg, '/responses', body, 'ai_video_post_call_provider_http');
    return {
      provider: cfg.provider,
      model: cfg.model,
      responseId: data?.id || null,
      payload: this.parseProviderPayload(this.extractResponsesText(data)),
    };
  }

  private normalizeHandoffStringArray(value: any, maxItems: number, maxLength = 240) {
    if (!Array.isArray(value)) return [];
    return value
      .map((item) => String(item || '').trim())
      .filter(Boolean)
      .map((item) => item.slice(0, maxLength))
      .slice(0, maxItems);
  }

  private normalizeQuestionsAnswered(value: any) {
    if (!Array.isArray(value)) return [];
    return value
      .map((item) => {
        const question = String(item?.question || '').trim();
        const answer = String(item?.answer || '').trim();
        if (!question || !answer) return null;
        return { question: question.slice(0, 280), answer: answer.slice(0, 600) };
      })
      .filter(Boolean)
      .slice(0, 12);
  }

  private normalizeSessionHandoffPayload(payload: any, context: AiSessionHandoffContext) {
    const summaryText = String(payload?.summaryText || '').trim().slice(0, 2000);
    if (!summaryText) throw new BadGatewayException('ai_handoff_summary_required');
    const rawUrgency = String(payload?.urgency || context.session?.priority || '').trim().toLowerCase();
    const urgency = ['routine', 'urgent', 'emergency'].includes(rawUrgency) ? rawUrgency : 'routine';
    return {
      urgency,
      summaryText,
      reportedSigns: this.normalizeHandoffStringArray(payload?.reportedSigns, 12),
      redFlags: this.normalizeHandoffStringArray(payload?.redFlags, 8),
      questionsAnswered: this.normalizeQuestionsAnswered(payload?.questionsAnswered),
      questionsUnanswered: this.normalizeHandoffStringArray(payload?.questionsUnanswered, 10),
      recommendedFirstChecks: this.normalizeHandoffStringArray(payload?.recommendedFirstChecks, 8),
    };
  }

  private normalizeHandoffAiContext(value: Record<string, any> | null | undefined) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
    const messages = Array.isArray(value.messages)
      ? value.messages.map((message) => ({
          role: String(message?.role || '').slice(0, 24),
          content: String(message?.content || '').slice(0, 1200),
          metadata: message?.metadata && typeof message.metadata === 'object' && !Array.isArray(message.metadata) ? message.metadata : undefined,
        })).filter((message) => message.content.trim()).slice(-12)
      : [];
    return {
      source: String(value.source || '').slice(0, 80),
      aiEventId: String(value.aiEventId || '').slice(0, 80),
      assistantPayload: value.assistantPayload && typeof value.assistantPayload === 'object' && !Array.isArray(value.assistantPayload)
        ? value.assistantPayload
        : null,
      routing: value.routing && typeof value.routing === 'object' && !Array.isArray(value.routing) ? value.routing : null,
      messages,
    };
  }

  private async buildSessionHandoffContext(actorUserId: string, sessionId: string, sourceAiEventId: string | null, aiContext: Record<string, any> | null): Promise<AiSessionHandoffContext> {
    const normalizedAiContext = this.normalizeHandoffAiContext(aiContext);
    return this.db.runInTx(async (q) => {
      const { rows: sessionRows } = await q<any>(
        `select s.id::text as session_id,
                s.user_id::text,
                s.vet_id::text,
                s.pet_id::text,
                s.specialty_id::text,
                s.priority,
                s.status,
                s.mode,
                s.started_at,
                p.name as pet_name,
                to_jsonb(p) - 'embedding' as pet,
                to_jsonb(h) - 'embedding' as health_profile,
                vu.full_name as vet_name,
                vs.name as specialty_name
           from chat_sessions s
      left join pets p on p.id = s.pet_id
      left join pet_health_profiles h on h.pet_id = p.id
      left join users vu on vu.id = s.vet_id
      left join vet_specialties vs on vs.id = s.specialty_id
          where s.id = $1::uuid
            and (s.user_id = auth.uid() or s.vet_id = auth.uid() or is_admin())
          limit 1`,
        [sessionId]
      );
      const session = sessionRows[0];
      if (!session) throw new BadRequestException('session_not_found_for_handoff');

      const eventQuery = sourceAiEventId
        ? q<any>(
            `select id::text, event_type, status, response_payload, created_at
               from ai_events
              where id = $1::uuid
                and (actor_user_id = auth.uid() or session_id = $2::uuid or pet_id = $3::uuid or is_admin())
              limit 1`,
            [sourceAiEventId, sessionId, session.pet_id]
          )
        : q<any>(
            `select id::text, event_type, status, response_payload, created_at
               from ai_events
              where actor_user_id = auth.uid()
                and event_type = 'ai.chat_turn.run'
                and ($1::uuid is null or pet_id = $1::uuid or session_id = $2::uuid)
              order by created_at desc
              limit 3`,
            [session.pet_id, sessionId]
          );
      const { rows: eventRows } = await eventQuery;
      const sourceAiEvents = eventRows.map((row) => ({
        id: row.id,
        eventType: row.event_type,
        status: row.status,
        createdAt: row.created_at,
        payload: row.response_payload?.payload || null,
        toolResults: Array.isArray(row.response_payload?.toolResults) ? row.response_payload.toolResults : [],
      }));
      return { actorUserId, session, aiContext: normalizedAiContext, sourceAiEvents };
    });
  }

  private async callSessionHandoffProvider(context: AiSessionHandoffContext, dryRun = false) {
    const cfg = this.providerConfig(undefined, dryRun);
    if (dryRun) {
      const assistantPayload = context.aiContext?.assistantPayload || {};
      return {
        provider: cfg.provider,
        model: cfg.model,
        responseId: null,
        payload: {
          urgency: String(assistantPayload.urgency || context.session.priority || 'routine'),
          summaryText: String(assistantPayload.handoffSummary || assistantPayload.caseSummary || '').slice(0, 2000),
          reportedSigns: [],
          redFlags: [],
          questionsAnswered: [],
          questionsUnanswered: [],
          recommendedFirstChecks: [],
        },
      };
    }
    if (!cfg.apiKey) throw new ServiceUnavailableException('ai_provider_not_configured');
    if (cfg.apiMode !== 'responses') throw new ServiceUnavailableException('ai_handoff_requires_responses_api');
    const body: Record<string, any> = {
      model: cfg.model,
      store: false,
      instructions: this.sessionHandoffInstructions(),
      input: [{ role: 'user', content: JSON.stringify(context) }],
      text: { format: this.sessionHandoffResponseFormat() },
    };
    if (cfg.reasoningEffort) body.reasoning = { effort: cfg.reasoningEffort };
    const data = await this.postProviderJson(cfg, '/responses', body, 'ai_handoff_provider_http');
    return {
      provider: cfg.provider,
      model: cfg.model,
      responseId: data?.id || null,
      payload: this.parseProviderPayload(this.extractResponsesText(data)),
    };
  }

  private async upsertSessionHandoff(args: {
    context: AiSessionHandoffContext;
    eventId: string;
    sourceAiEventId: string | null;
    payload: ReturnType<AiService['normalizeSessionHandoffPayload']>;
  }) {
    const { rows } = await this.db.runInTx(async (q) => q<any>(
      `insert into ai_handoffs (
         id, session_id, ai_event_id, source_ai_event_id, actor_user_id, pet_id, vet_id, specialty_id,
         urgency, summary_text, reported_signs, red_flags, questions_answered, questions_unanswered,
         recommended_first_checks, source_payload, created_at, updated_at
       ) values (
         gen_random_uuid(), $1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid, $7::uuid,
         $8, $9, $10::jsonb, $11::jsonb, $12::jsonb, $13::jsonb, $14::jsonb, $15::jsonb, now(), now()
       )
       on conflict (session_id) do update
          set ai_event_id = excluded.ai_event_id,
              source_ai_event_id = excluded.source_ai_event_id,
              actor_user_id = excluded.actor_user_id,
              pet_id = excluded.pet_id,
              vet_id = excluded.vet_id,
              specialty_id = excluded.specialty_id,
              urgency = excluded.urgency,
              summary_text = excluded.summary_text,
              reported_signs = excluded.reported_signs,
              red_flags = excluded.red_flags,
              questions_answered = excluded.questions_answered,
              questions_unanswered = excluded.questions_unanswered,
              recommended_first_checks = excluded.recommended_first_checks,
              source_payload = excluded.source_payload,
              updated_at = now()
       returning id, session_id, ai_event_id, source_ai_event_id, actor_user_id, pet_id, vet_id, specialty_id,
                 urgency, summary_text, reported_signs, red_flags, questions_answered, questions_unanswered,
                 recommended_first_checks, created_at, updated_at`,
      [
        args.context.session.session_id,
        args.eventId,
        args.sourceAiEventId,
        args.context.actorUserId,
        args.context.session.pet_id || null,
        args.context.session.vet_id || null,
        args.context.session.specialty_id || null,
        args.payload.urgency,
        args.payload.summaryText,
        JSON.stringify(args.payload.reportedSigns),
        JSON.stringify(args.payload.redFlags),
        JSON.stringify(args.payload.questionsAnswered),
        JSON.stringify(args.payload.questionsUnanswered),
        JSON.stringify(args.payload.recommendedFirstChecks),
        JSON.stringify({ aiContext: args.context.aiContext, sourceAiEvents: args.context.sourceAiEvents }),
      ]
    ));
    return rows[0] || null;
  }

  private chatTurnTools() {
    return [
      {
        type: 'function',
        name: 'recommend_specialty',
        description: 'Choose the best existing veterinary specialty for the user need. Use this before offering human chat, video, or scheduling.',
        strict: true,
        parameters: {
          type: 'object',
          additionalProperties: false,
          required: ['symptoms', 'petId'],
          properties: {
            symptoms: { type: 'string', description: 'User-described need, symptoms, or reason for contacting a veterinarian.' },
            petId: { type: ['string', 'null'], description: 'Exact pet UUID from server context only. Use null if unsure, if the user did not identify the horse, or if no exact context id matches.' },
          },
        },
      },
      {
        type: 'function',
        name: 'find_vets',
        description: 'Find approved vets that cover a selected active specialty, including current load and next available scheduled-video slot. Use after a specialty is known and before presenting service options.',
        strict: true,
        parameters: {
          type: 'object',
          additionalProperties: false,
          required: ['specialtyId', 'limit'],
          properties: {
            specialtyId: { type: ['string', 'null'], description: 'Specialty UUID from recommend_specialty, or null to list approved vets.' },
            limit: { type: 'integer', minimum: 1, maximum: 5, description: 'Maximum vets to return.' },
          },
        },
      },
      {
        type: 'function',
        name: 'check_service_access',
        description: 'Preflight whether the current user appears to have subscription allowance for chat or video. This does not reserve or consume entitlement.',
        strict: true,
        parameters: {
          type: 'object',
          additionalProperties: false,
          required: ['serviceType'],
          properties: {
            serviceType: { type: 'string', enum: ['chat', 'video'], description: 'Service the user wants to activate.' },
          },
        },
      },
      {
        type: 'function',
        name: 'get_available_slots',
        description: 'Find available future appointment slots for an approved vet. Use when the user wants to schedule a video call.',
        strict: true,
        parameters: {
          type: 'object',
          additionalProperties: false,
          required: ['vetId', 'since', 'until', 'durationMin'],
          properties: {
            vetId: { type: 'string', description: 'Approved vet UUID.' },
            since: { type: ['string', 'null'], description: 'ISO date-time lower bound, or null for now.' },
            until: { type: ['string', 'null'], description: 'ISO date-time upper bound, or null for seven days from now.' },
            durationMin: { type: ['integer', 'null'], minimum: 10, maximum: 240, description: 'Requested slot length in minutes, or null for 30.' },
          },
        },
      },
      {
        type: 'function',
        name: 'schedule_video',
        description: 'Book a scheduled video appointment after the user has explicitly confirmed one concrete available slot. Re-checks availability server-side before creating the appointment.',
        strict: true,
        parameters: {
          type: 'object',
          additionalProperties: false,
          required: ['vetId', 'petId', 'specialtyId', 'startsAt', 'durationMin', 'confirmationToken'],
          properties: {
            vetId: { type: 'string', description: 'Approved vet UUID from find_vets or get_available_slots context.' },
            petId: { type: ['string', 'null'], description: 'Exact pet UUID from server context, or null only if the user has no selected horse.' },
            specialtyId: { type: 'string', description: 'Specialty UUID from recommend_specialty.' },
            startsAt: { type: 'string', description: 'Exact ISO date-time for the user-confirmed slot.' },
            durationMin: { type: ['integer', 'null'], minimum: 10, maximum: 240, description: 'Confirmed duration in minutes, or null for 30.' },
            confirmationToken: { type: ['string', 'null'], description: 'Short natural-language evidence that the user confirmed this exact slot, or null if unavailable.' },
          },
        },
      },
      {
        type: 'function',
        name: 'schedule_chat',
        description: 'Book a scheduled chat appointment after the user has explicitly confirmed one concrete available slot. Re-checks availability server-side before creating the appointment.',
        strict: true,
        parameters: {
          type: 'object',
          additionalProperties: false,
          required: ['vetId', 'petId', 'specialtyId', 'startsAt', 'durationMin', 'confirmationToken'],
          properties: {
            vetId: { type: 'string', description: 'Approved vet UUID from find_vets or get_available_slots context.' },
            petId: { type: ['string', 'null'], description: 'Exact pet UUID from server context, or null only if the user has no selected horse.' },
            specialtyId: { type: 'string', description: 'Specialty UUID from recommend_specialty.' },
            startsAt: { type: 'string', description: 'Exact ISO date-time for the user-confirmed slot.' },
            durationMin: { type: ['integer', 'null'], minimum: 10, maximum: 240, description: 'Confirmed duration in minutes, or null for 30.' },
            confirmationToken: { type: ['string', 'null'], description: 'Short natural-language evidence that the user confirmed this exact slot, or null if unavailable.' },
          },
        },
      },
    ];
  }

  private async postProviderJson(cfg: AiProviderConfig, path: string, body: Record<string, any>, errorPrefix: string) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), cfg.timeoutMs);
    try {
      const response = await fetch(`${cfg.baseUrl}${path}`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${cfg.apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(body),
        signal: controller.signal,
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new BadGatewayException(data?.error?.message || `${errorPrefix}_${response.status}`);
      }
      return data;
    } catch (error: any) {
      if (error?.name === 'AbortError') {
        throw new GatewayTimeoutException(`${errorPrefix}_timeout`);
      }
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }

  private extractResponsesText(data: any) {
    if (typeof data?.output_text === 'string' && data.output_text.trim()) return data.output_text;
    const parts: string[] = [];
    for (const item of Array.isArray(data?.output) ? data.output : []) {
      if (item?.type === 'function_call' || item?.type === 'custom_tool_call') {
        throw new BadGatewayException('ai_provider_tool_call_unhandled');
      }
      if (item?.type !== 'message' || !Array.isArray(item.content)) continue;
      for (const content of item.content) {
        if (content?.type === 'refusal') throw new BadGatewayException('ai_provider_refusal');
        if (content?.type === 'output_text' && typeof content.text === 'string') parts.push(content.text);
      }
    }
    return parts.join('').trim();
  }

  private parseProviderPayload(content: string) {
    if (!content || typeof content !== 'string') throw new BadGatewayException('ai_provider_empty_response');
    try {
      return JSON.parse(content);
    } catch {
      throw new BadGatewayException('ai_provider_invalid_json');
    }
  }

  private compactChatPet(pet: any, healthProfile: any) {
    if (!pet || typeof pet !== 'object') return null;
    const { user_id, embedding, ...safePet } = pet;
    const { pet_id, embedding: healthEmbedding, ...safeHealth } = healthProfile || {};
    return {
      ...safePet,
      healthProfile: healthProfile ? safeHealth : null,
    };
  }

  private async buildChatTurnContext(actorUserId: string, petId: string | null, sessionId: string | null, conversationId: string | null): Promise<AiChatTurnContext> {
    const base = { actorUserId, petId, sessionId, conversationId };
    if (this.db.isStub) return { ...base, user: null, pets: [], subscription: null, recentConversations: [] };

    return this.db.runInTx(async (q) => {
      const [userRows, petRows, subscriptionRows, conversationRows] = await Promise.all([
        q<any>(
          `select id::text, full_name, email, phone, country, state, customer_type, is_verified
             from users
            where id = $1::uuid
            limit 1`,
          [actorUserId]
        ),
        q<any>(
          `select to_jsonb(p) as pet,
                  to_jsonb(h) as health_profile
             from pets p
             left join pet_health_profiles h on h.pet_id = p.id
            where p.user_id = $1::uuid
              and ($2::uuid is null or p.id = $2::uuid)
            order by p.created_at desc
            limit 20`,
          [actorUserId, petId]
        ),
        q<any>(
          `select us.id::text as subscription_id,
                  us.status,
                  us.current_period_start,
                  us.current_period_end,
                  us.cancel_at_period_end,
                  us.pets_included,
                  p.code as plan_code,
                  p.name as plan_name,
                  p.included_chats,
                  p.included_videos,
                  p.pets_included_default,
                  coalesce(su.consumed_chats, 0)::int as consumed_chats,
                  coalesce(su.consumed_videos, 0)::int as consumed_videos
             from user_subscriptions us
             join subscription_plans p on p.id = us.plan_id
        left join subscription_usage su
               on su.subscription_id = us.id
              and su.period_start = us.current_period_start
              and su.period_end = us.current_period_end
            where us.user_id = $1::uuid
              and ${this.entitlements.activeSubscriptionSql('us')}
            order by us.current_period_end desc nulls last
            limit 1`,
          [actorUserId]
        ),
        q<any>(
          `select s.id::text as session_id,
                  s.mode,
                  s.status,
                  s.pet_id::text,
                  p.name as pet_name,
                  s.started_at,
                  s.ended_at,
                  (
                    select coalesce(json_agg(row_to_json(mm)), '[]'::json)
                      from (
                        select role, left(content, 240) as content, created_at
                          from messages
                         where session_id = s.id
                           and deleted_at is null
                         order by created_at desc
                         limit 4
                      ) mm
                  ) as recent_messages
             from chat_sessions s
             left join pets p on p.id = s.pet_id
            where s.user_id = $1::uuid
              and ($2::uuid is null or s.pet_id = $2::uuid)
            order by coalesce(s.started_at, s.created_at) desc
            limit 5`,
          [actorUserId, petId]
        ),
      ]);

      const subscription = subscriptionRows.rows[0] || null;
      const recentConversations = conversationRows.rows.map((row) => {
        if (sessionId) return row;
        return { ...row, recent_messages: [] };
      });
      return {
        ...base,
        user: userRows.rows[0] || null,
        pets: petRows.rows.map((row) => this.compactChatPet(row.pet, row.health_profile)).filter(Boolean),
        subscription: subscription
          ? {
              ...subscription,
              remaining_chats: Math.max(Number(subscription.included_chats || 0) - Number(subscription.consumed_chats || 0), 0),
              remaining_videos: Math.max(Number(subscription.included_videos || 0) - Number(subscription.consumed_videos || 0), 0),
            }
          : null,
        recentConversations,
      };
    });
  }

  private chatTurnInstructions(context: AiChatTurnContext, state: AiChatTurnState) {
    return [
      'You are Call a Vet AI concierge for equine veterinary care.',
      'Reply in Spanish unless the user clearly uses another language.',
      'Your purpose is warm intake, urgency detection, specialty routing, entitlement-aware service recommendation, and concise coordination with professional human vets.',
      'Never diagnose, prescribe medication, recommend medication doses, or imply you replace a veterinarian.',
      'If red flags are present, recommend immediate professional help or local emergency veterinary care.',
      'Use the provided user, horse, subscription, and recent conversation context to personalize naturally. Do not expose raw internal IDs unless needed for tool calls.',
      'Recent conversations are historical only. Do not copy symptoms, urgency, or triage questions from them into the current case unless the user explicitly says this is the same issue or refers back to that prior case.',
      'If the latest user message is only a generic request to talk to a veterinarian and contains no clinical concern, do not infer appetite loss, colic, fever, swelling, breathing trouble, or any other specific symptom. Ask one neutral question about what they need today, or ask whether they prefer chat or video if enough context is already available.',
      'If the user has more than one horse and no specific pet is clear, ask which horse this is for before non-emergency service activation.',
      'For recommend_specialty petId, pass only an exact pet id from Server context. If unsure, pass null; missing or uncertain petId must not block intake.',
      'If the case may be urgent or emergency, especially appetite refusal for 24+ hours, colic signs, severe pain, fever, dehydration, respiratory distress, bleeding, or inability to stand, ask 2-3 concrete triage questions immediately. These questions must help determine urgency and create a useful handoff summary for the veterinarian.',
      'When asking intake questions, choose 2-3 questions total from the most relevant missing handoff domains: onset/progression; intake/output such as appetite, water, manure, or urine; local severity such as bleeding, swelling, wound, lameness, or discharge; systemic red flags such as fever, depression, abnormal breathing, pale gums, collapse, or severe pain; and context such as affected horse, medications, relevant history, trauma, or exposure.',
      'For urgent cases, make sure at least one question covers systemic red flags when that information is missing. Cover onset/progression when timing or worsening is unclear. Do not ask duplicate questions after the user answers intake.',
      'For urgent intake, do not lead with service-choice buttons or summary drafting. First ask the triage questions, then explain that the answers will help route to the right veterinarian faster.',
      'Ask the urgent triage question set only once. If the user has already answered those first urgent intake questions, do not ask another triage set or another generic follow-up.',
      'If the latest user message includes a concrete horse/case detail and asks to talk, connect, chat, call, video, or consult with a veterinarian, route immediately with tools instead of asking a generic preference question.',
      'After the user answers the first urgent intake questions, decide the specialty, urgency, and service type from the available information. Then use tools to route: recommend_specialty, find_vets for that specialty, check_service_access for the recommended service, and get_available_slots when scheduled_video or scheduled_chat is the best next step.',
      'After urgent intake answers, present the next action as chat, immediate video, scheduled video, or scheduled chat. If red flags remain, bias toward immediate video/local emergency care; if stable but needs review, choose chat, scheduled chat, or scheduled video based on service access and availability.',
      'Before recommending a service, gather the minimum missing context for a useful vet handoff: affected horse, main concern, onset/duration, severity, appetite/water, relevant history/medications, and red flags. Ask at most one concise follow-up at a time.',
      'Do not immediately ask the user to choose a product. Decide whether chat, immediate video, scheduled video, or scheduled chat is best based on urgency, symptoms, context, and entitlement signals; then explain the recommendation briefly.',
      'Prepare the conversation so a later veterinarian handoff can include a concise contextualization, not a diagnosis.',
      'Populate caseSummary, handoffSummary, and routingRationale whenever there is concrete case detail. Keep them concise, factual, and non-diagnostic; use null only when there is not enough detail.',
      'Set commerceRecommendation from entitlement context/tool results: included when the recommended service is available, one_off when allowance is exhausted but a one-time service is appropriate, upgrade_plan when there is no active subscription or a plan upgrade is the clearest next step, ask_more while context is missing, and none when no service should be offered.',
      'Use function tools to choose an existing specialty, find approved vets, check service access, and inspect availability.',
      'When the user wants scheduling, first clarify whether they prefer chat or video if that is not already clear. Once the mode is clear, call check_service_access for that mode before offering slots. If access is exhausted, return nextStep payment, commerceRecommendation one_off, and recommendedService scheduled_chat or scheduled_video so the app can sell the one-time consultation before scheduling. If access is available, call get_available_slots, present concrete options, and call schedule_video or schedule_chat only after the user confirms one exact slot. If the requested slot is no longer available, ask the user to choose another returned slot.',
      'If the prior assistant message listed numbered appointment slots and the latest user reply chooses a number or clearly confirms one listed option, call schedule_video or schedule_chat using the exact ISO slot from that numbered option. Do not ask triage questions again during slot selection.',
      'Do not invent specialty IDs, vet IDs, appointment slots, entitlements, prices, or session IDs.',
      'Before recommending chat or video activation, call check_service_access for the relevant service type.',
      'Keep final responses short, warm, and action-oriented. If context is insufficient, ask a targeted question instead of showing all service choices.',
      'Return nextStep as interview when the user should type an answer to intake, urgency, pet-selection, or handoff-context questions. During interview turns, do not offer service choices.',
      'Return nextStep as recommendation only when you have enough context to present chat, immediate video, or scheduled video as user actions. Recommendation turns must not contain numbered intake questions.',
      'Return nextStep as payment only when the best next action is buying a one-off service or upgrading a plan. Return activation or handoff only when the service has already been activated or handed off.',
      'When nextStep is recommendation or payment, write an AI-generated transition message that complements the product actions shown by the app and explains the user can continue by choosing one of the available actions.',
      'For recommendation or payment turns, do not include numbered_list blocks or intake-style questions. Use one short AI-generated transition paragraph and, if needed, one safety_note. The app will render the available product actions separately.',
      'Return formatVersion as 1 and populate displayBlocks as the source of truth for chat UI rendering. Keep message as a plain-text fallback composed from the same displayBlocks content.',
      'Use displayBlocks type paragraph for normal short copy, numbered_list for ordered questions, bullet_list for short option lists, and safety_note for concise emergency or urgent escalation copy.',
      'For paragraph and safety_note blocks, set text to the visible sentence or short paragraph and items to an empty array. For numbered_list and bullet_list blocks, set text to null and put each visible row in items.',
      'Never put manual list markers inside displayBlocks items: no "1.", "1)", hyphens, bullets, or Markdown markers. The client will render numbering and bullets.',
      'Do not use Markdown headings, bold markers, or decorative formatting in message or displayBlocks.',
      'When asking urgent triage questions, place the brief setup sentence in a paragraph or safety_note block and place the 2-3 triage questions in one numbered_list block.',
      `Server context: ${JSON.stringify(context)}`,
      `Conversation state: ${JSON.stringify(state)}`,
    ].join('\n');
  }

  private normalizeChatMessages(input: AiChatTurnInput) {
    const messages = Array.isArray(input.messages) ? input.messages : [];
    const normalized = messages
      .map((message) => {
        const content = String(message?.content || '').trim();
        if (!content) return null;
        const role = message?.role === 'assistant' || message?.role === 'ai' ? 'assistant' : 'user';
        const metadata = message?.metadata && typeof message.metadata === 'object' && !Array.isArray(message.metadata)
          ? message.metadata
          : undefined;
        return { role, content, metadata };
      })
      .filter(Boolean) as Array<{ role: 'user' | 'assistant'; content: string; metadata?: AiChatMessageInput['metadata'] }>;
    const currentMessage = String(input.message || '').trim();
    if (currentMessage) normalized.push({ role: 'user', content: currentMessage });
    return normalized.slice(-12);
  }

  private chatTurnState(messages: Array<{ role: 'user' | 'assistant'; content: string; metadata?: AiChatMessageInput['metadata'] }>): AiChatTurnState {
    const priorMessages = messages.slice(0, -1);
    const latestMessage = messages[messages.length - 1]?.content || '';
    const latestPriorAssistantMessage = [...priorMessages].reverse().find((message) => message.role === 'assistant');
    const latestPriorAssistant = latestPriorAssistantMessage?.content || '';
    const latestPriorMetadata = latestPriorAssistantMessage?.metadata || {};
    const metadataQuestions = Array.isArray(latestPriorMetadata.intakeQuestions)
      ? latestPriorMetadata.intakeQuestions.map((question) => String(question || '').trim()).filter(Boolean)
      : [];
    const metadataNextStep = this.normalizeChatNextStep(latestPriorMetadata.nextStep);
    const metadataUrgentIntakeAsked = metadataNextStep === 'interview' && metadataQuestions.length > 0;
    const urgentIntakeAlreadyAsked = metadataUrgentIntakeAsked
      || /dolor abdominal|flancos|hecho heces|ha hecho heces|defecad|pop[oó]|encías pálidas|sangre en las encías|sangrado|respiración agitada|cólico|dificultad para tragar|responder preguntas de urgencia|valorar urgencia/i.test(latestPriorAssistant)
      || priorMessages.some((message) => message.role === 'assistant' && /dolor abdominal|hecho heces|encías pálidas|responder preguntas de urgencia/i.test(message.content));
    const afterUrgentIntakeAnswer = urgentIntakeAlreadyAsked && messages[messages.length - 1]?.role === 'user';
    const latestUserLikelyAnsweringIntake = afterUrgentIntakeAnswer && (
      /(^|\s)(1[.)]|2[.)]|3[.)])\s*/.test(latestMessage)
      || metadataQuestions.length > 0
      || /sí|si |no |poca|poco|normal|agua|heces|pop[oó]|dolor|sangre|fiebre|deca[ií]do|respira|come|comer/i.test(latestMessage)
    );
    const clinicalSignal = this.hasClinicalSignal(latestMessage);
    const caseDetailSignal = clinicalSignal || this.hasCaseDetailSignal(latestMessage);
    const latestText = this.normalizeCareText(latestMessage);
    const priorSchedulingQuestion = /agendar|agenda|programar|horario|horarios|opciones disponibles|elige|slot|prefieres.*(chat|video)|chat o.*video|video o.*chat/i.test(latestPriorAssistant);
    const priorSchedulingStage = String((latestPriorMetadata as any).schedulingStage || '').trim().toLowerCase() || null;
    const priorSchedulingRange = String((latestPriorMetadata as any).schedulingRange || '').trim().toLowerCase() || null;
    const priorSchedulingDaypart = String((latestPriorMetadata as any).schedulingDaypart || '').trim().toLowerCase() || null;
    const wantsScheduling = /agendar|agenda|programar|cita|manana|mañana|tarde|fecha|horario|slot|disponible/.test(latestText)
      || (priorSchedulingQuestion && /chat|video|videollamada|llamada|mensaje|mensajes|perfecto|ok|okay|si|sí|va|dale|confirmo|confirmar|^[1-5]$|opcion|opción|primera|segunda|tercera/.test(latestText));
    const selectedRange = priorSchedulingStage === 'date_range'
      ? (/hoy|today/.test(latestText) ? 'today' : /proxima|próxima|siguiente|next/.test(latestText) ? 'next_week' : 'this_week')
      : priorSchedulingRange;
    const selectedDaypart = priorSchedulingStage === 'daypart'
      ? (/mañana|manana|morning/.test(latestText) ? 'morning' : /noche|evening/.test(latestText) ? 'evening' : 'afternoon')
      : priorSchedulingDaypart;
    return {
      urgentIntakeAlreadyAsked,
      afterUrgentIntakeAnswer,
      latestUserLikelyAnsweringIntake,
      clinicalSignal,
      caseDetailSignal,
      explicitCareRequest: caseDetailSignal && this.wantsCareRequest(latestMessage),
      wantsScheduling,
      schedulingStage: priorSchedulingStage,
      schedulingRange: selectedRange,
      schedulingDaypart: selectedDaypart,
    };
  }

  private parseToolArguments(raw: string) {
    try {
      const parsed = JSON.parse(raw || '{}');
      return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed as Record<string, any> : {};
    } catch {
      throw new BadGatewayException('ai_tool_arguments_invalid_json');
    }
  }

  private async recommendSpecialtyTool(args: Record<string, any>, context: AiChatTurnContext) {
    const symptoms = String(args.symptoms || '').trim();
    const toolPetId = this.normalizeOptionalToolUuid(args.petId, 'petId');
    let selectedPetId = context.petId || null;
    let ignoredPetId: string | null = null;
    if (toolPetId) {
      const isKnownContextPet = context.pets.some((pet) => String(pet?.id || '') === toolPetId);
      if (isKnownContextPet || toolPetId === context.petId) {
        selectedPetId = toolPetId;
      } else {
        const { rows } = await this.db.query<{ id: string }>(
          `select id from pets where id = $1::uuid and user_id = $2::uuid limit 1`,
          [toolPetId, context.actorUserId]
        );
        selectedPetId = rows[0]?.id || selectedPetId;
        ignoredPetId = rows[0] ? null : toolPetId;
      }
    }
    if (!selectedPetId && context.pets.length === 1) {
      selectedPetId = String(context.pets[0]?.id || '') || null;
    }
    if (selectedPetId && !this.normalizeOptionalToolUuid(selectedPetId, 'petId')) {
      selectedPetId = null;
    }
    if (selectedPetId && selectedPetId !== context.petId && !context.pets.some((pet) => String(pet?.id || '') === selectedPetId)) {
      const { rows } = await this.db.query<{ id: string }>(
        `select id from pets where id = $1::uuid and user_id = $2::uuid limit 1`,
        [selectedPetId, context.actorUserId]
      );
      if (!rows[0]) selectedPetId = null;
    }
    const { rows } = await this.db.query<any>(
      `select distinct on (lower(btrim(name))) id, name, description, coalesce(is_active, true) as is_active, sort_order
         from vet_specialties
        where nullif(btrim(name), '') is not null
        order by lower(btrim(name)), coalesce(is_active, true) desc, length(coalesce(description, '')) desc, id asc`
    );
    const haystack = symptoms.toLowerCase();
    const appetiteConcern = /no quiere comer|no come|dej[oó] de comer|apetito|anorex|desde antier|desde ayer|colic|cólico|diarrea/.test(haystack);
    const emergencyConcern = /no se levanta|respira|sangre|sangrado|dolor fuerte|suda|rueda|se echa|emergencia|urgente/.test(haystack);
    const boostedTerms = [
      { terms: ['no quiere comer', 'no come', 'dejo de comer', 'dejó de comer', 'apetito', 'colico', 'cólico', 'diarrea', 'gastro'], targets: ['gastro', 'interna', 'internal', 'urgenc', 'critical', 'crítico'] },
      { terms: ['cojea', 'cojera', 'lameness', 'renguera', 'pata', 'tendon', 'tendón', 'articular'], targets: ['cojera', 'ortopedia', 'lameness', 'orthopedic', 'deportiva', 'rehabilit'] },
      { terms: ['piel', 'dermat', 'alergia', 'comezon', 'comezón', 'picazón', 'rash', 'herida superficial'], targets: ['dermat', 'piel'] },
      { terms: ['ojo', 'vision', 'visión', 'lagrimeo', 'cornea', 'córnea'], targets: ['oftal', 'ophthalm', 'ojo'] },
      { terms: ['diente', 'boca', 'masticar', 'dent'], targets: ['odonto', 'dent'] },
      { terms: ['parto', 'preñada', 'prenada', 'gestacion', 'gestación', 'fertilidad', 'reprodu'], targets: ['repro', 'fertilidad'] },
      { terms: ['sangre', 'no se levanta', 'respira', 'emergencia', 'urgente', 'dolor fuerte'], targets: ['urgenc', 'emergency', 'critical', 'crítico', 'general'] },
      { terms: ['vacuna', 'vacunar', 'chequeo', 'revision', 'revisión', 'preventivo'], targets: ['general', 'prevent'] },
      { terms: ['dieta', 'alimento', 'forraje', 'suplemento', 'peso', 'nutric'], targets: ['nutri', 'aliment'] },
    ];
    const isActiveSpecialty = (specialty: any) => specialty?.is_active !== false;
    const scored = rows.map((specialty) => {
      const name = String(specialty.name || '').toLowerCase();
      const description = String(specialty.description || '').toLowerCase();
      const terms = `${name} ${description}`.split(/[^a-z0-9áéíóúüñ]+/i).filter((term) => term.length > 3);
      const baseScore = terms.reduce((sum, term) => sum + (haystack.includes(term.toLowerCase()) ? 1 : 0), 0) + (haystack.includes(name) ? 5 : 0);
      const boost = boostedTerms.reduce((sum, group) => {
        const symptomMatches = group.terms.some((term) => haystack.includes(term));
        const specialtyMatches = group.targets.some((target) => name.includes(target) || description.includes(target));
        return sum + (symptomMatches && specialtyMatches ? 4 : 0);
      }, 0);
      const clinicalBoost = (appetiteConcern && name.includes('gastro')) ? 10
        : (appetiteConcern && (name.includes('urgenc') || description.includes('cólico'))) ? 8
          : (appetiteConcern && name.includes('interna')) ? 6
            : (emergencyConcern && (name.includes('urgenc') || description.includes('estabilización'))) ? 10
              : (appetiteConcern && name.includes('medicina general')) ? 1
                : 0;
      const score = baseScore + boost + clinicalBoost;
      return { specialty, score };
    }).sort((left, right) => right.score - left.score || Number(left.specialty.sort_order || 100) - Number(right.specialty.sort_order || 100));
    const generalFallback = scored.find((item) => {
      const name = String(item.specialty?.name || '').toLowerCase();
      return isActiveSpecialty(item.specialty) && (name.includes('medicina general') || name.includes('general practice'));
    })?.specialty || rows.find(isActiveSpecialty) || null;
    const bestMatch = scored.find((item) => item.score > 0) || null;
    const selected = bestMatch
      ? (isActiveSpecialty(bestMatch.specialty) ? bestMatch.specialty : generalFallback)
      : generalFallback;
    const usedFallback = !!selected && (!bestMatch || bestMatch.specialty.id !== selected.id);
    return {
      ok: !!selected,
      specialty: selected,
      candidates: scored.slice(0, 5).map((item) => ({ ...item.specialty, score: item.score })),
      confidence: usedFallback ? 'low' : scored[0]?.score >= 5 ? 'high' : scored[0]?.score > 0 ? 'medium' : 'low',
      fallbackUsed: usedFallback,
      petId: selectedPetId,
      ignoredPetId: ignoredPetId ? true : undefined,
    };
  }

  private urgentIntakeQuestions(context: AiChatTurnContext) {
    const petName = context.pets.length === 1 && context.pets[0]?.name
      ? String(context.pets[0].name)
      : 'tu caballo';
    return [
      `¿${petName} muestra dolor abdominal: se mira los flancos, patea el suelo, se echa/rueda, suda o está inquieto?`,
      `¿Ha tomado agua y ha hecho heces desde que dejó de comer?`,
      `¿Tiene fiebre, encías pálidas, respiración agitada o está muy decaído?`,
    ];
  }

  private fallbackIntakeQuestions(latestMessage: string, context: AiChatTurnContext) {
    const text = this.normalizeCareText(latestMessage);
    if (/cojea|cojera|cojo|renquea|renguea|claudica|pata|extremidad|casco|tendon/.test(text)) {
      return [
        '¿Desde cuándo cojea y fue de golpe o empezó poco a poco?',
        '¿Apoya la pata o casi no la usa?',
        '¿Ves hinchazón, calor en la pata o el casco, o alguna herida?',
      ];
    }
    return this.urgentIntakeQuestions(context);
  }

  private shouldAskUrgentIntake(payload: any, latestMessage: string, state: AiChatTurnState) {
    if (state.wantsScheduling) return false;
    if (state.urgentIntakeAlreadyAsked) return false;
    const text = this.normalizeCareText(latestMessage);
    return payload?.urgency === 'urgent'
      || payload?.urgency === 'emergency'
      || payload?.safetyEscalation === true
      || /no quiere comer|no come|dejo de comer|apetito|desde antier|desde ayer|colic|colico|dolor|fiebre|no se levanta|respira/.test(text);
  }

  private normalizeCareText(text: string) {
    return String(text || '')
      .toLowerCase()
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '');
  }

  private hasClinicalSignal(text: string) {
    const normalized = this.normalizeCareText(text);
    return /no quiere comer|no come|dejo de comer|apetito|colic|colico|dolor|fiebre|no se levanta|respira|respiracion|hinchazon|babea|baba|sangre|herida|cojea|cojera|cojo|renquea|renguea|claudica|pata|extremidad|casco|tendon|tos|diarrea|vomito|mal aliento|descarga|secrecion|decaido|suda|inquieto|abdomen|mandibula|tragar/.test(normalized);
  }

  private hasCaseDetailSignal(latestMessage: string) {
    const normalized = this.normalizeCareText(latestMessage);
    const hasAnimalReference = /\b(caballo|caballos|yegua|yeguas|potro|potra|equino|equinos|animal|mascota)\b/.test(normalized);
    const genericStripped = normalized
      .replace(/\b(hablar|platicar|contactar|conectar|consultar|consulta|necesito|necesita|necesitan|quiero|quiere|quisiera|ayuda|ayudar|veterinario|veterinaria|veterinarios|veterinarias|vet|doctor|doctora|chat|video|videollamada|llamada|llamar|atencion|servicio|ahora|hoy|por favor)\b/g, ' ')
      .replace(/\b(mi|mis|el|la|los|las|un|una|unos|unas|de|del|con|para|por|que|se|le|lo|su|sus|es|esta|estan|tiene|tengo|hay)\b/g, ' ');
    const detailTokens = genericStripped
      .split(/[^a-z0-9]+/)
      .map((token) => token.trim())
      .filter((token) => token.length >= 3);
    return hasAnimalReference ? detailTokens.length >= 2 : detailTokens.length >= 4;
  }

  private wantsCareRequest(latestMessage: string) {
    const text = this.normalizeCareText(latestMessage);
    return /\b(hablar|platicar|contactar|conectar|consultar|necesito|quiero|quisiera)\b.*\b(veterinari[oa]|vet|doctor|doctora)\b|\b(veterinari[oa]|vet|doctor|doctora)\b.*\b(hablar|consulta|chat|video|videollamada|llamada)\b|\b(chat|video|videollamada|llamada)\b.*\b(ahora|hoy|veterinari[oa]|vet|doctor|doctora)\b/.test(text);
  }

  private isGenericVetRequest(latestMessage: string) {
    return this.wantsCareRequest(latestMessage) && !this.hasClinicalSignal(latestMessage) && !this.hasCaseDetailSignal(latestMessage);
  }

  private latestServiceAccessToolResult(toolResults: Array<{ name: string; output: any }>) {
    for (const result of [...toolResults].reverse()) {
      if (result.name !== 'check_service_access') continue;
      const output = result.output || {};
      const serviceType = String(output.serviceType || '').toLowerCase();
      if (serviceType === 'chat' || serviceType === 'video') return output;
    }
    return null;
  }

  private latestAvailableSlotsToolResult(toolResults: Array<{ name: string; output: any }>) {
    for (const result of [...toolResults].reverse()) {
      if (result.name !== 'get_available_slots') continue;
      const output = result.output || {};
      const slots = Array.isArray(output.slots) ? output.slots : [];
      if (slots.length) return output;
    }
    return null;
  }

  private schedulingModeFromContext(payload: any, toolResults: Array<{ name: string; output: any }>) {
    const recommended = String(payload?.recommendedService || '').toLowerCase();
    if (recommended === 'scheduled_chat') return 'chat';
    if (recommended === 'scheduled_video') return 'video';
    const access = this.latestServiceAccessToolResult(toolResults);
    const accessType = String(access?.serviceType || '').toLowerCase();
    return accessType === 'chat' ? 'chat' : 'video';
  }

  private formatSlotForUser(start: unknown, end: unknown, index: number) {
    const normalizeDate = (value: unknown) => {
      if (value instanceof Date && !Number.isNaN(value.getTime())) return value.toISOString();
      const date = new Date(String(value || '').trim());
      return Number.isNaN(date.getTime()) ? String(value || '').trim() : date.toISOString();
    };
    const startText = normalizeDate(start);
    const endText = normalizeDate(end);
    return endText
      ? `${index + 1}. ${startText} a ${endText}`
      : `${index + 1}. ${startText}`;
  }

  private forceSchedulingSlotOffer(payload: any, toolResults: Array<{ name: string; output: any }>) {
    const slotsOutput = this.latestAvailableSlotsToolResult(toolResults);
    if (!slotsOutput) return null;
    const slots: Array<{ start: string; end: string }> = (Array.isArray(slotsOutput.slots) ? slotsOutput.slots : [])
      .map((slot: any) => ({ start: String(slot?.start || '').trim(), end: String(slot?.end || '').trim() }))
      .filter((slot: { start: string; end: string }) => slot.start)
      .slice(0, 5);
    if (!slots.length) return null;
    const mode = this.schedulingModeFromContext(payload, toolResults);
    const serviceLabel = mode === 'chat' ? 'chat' : 'videollamada';
    return {
      ...payload,
      message: `Tengo estos horarios disponibles para agendar la ${serviceLabel}. Responde con el número del horario que prefieres.\n${slots.map((slot, index) => this.formatSlotForUser(slot.start, slot.end, index)).join('\n')}`,
      nextStep: 'interview',
      recommendedService: null,
      actionLabel: 'Elegir horario',
      intakeQuestions: [],
      commerceRecommendation: 'included',
      schedulingStage: 'slot',
      schedulingMode: mode,
      schedulingRange: payload?.schedulingRange || null,
      schedulingDaypart: payload?.schedulingDaypart || null,
      schedulingOptions: slots.map((slot, index) => ({
        label: this.formatSlotForUser(slot.start, slot.end, index).replace(/^\d+[.)]\s*/, ''),
        value: String(index + 1),
        start: this.formatSlotForUser(slot.start, slot.end, index).replace(/^\d+[.)]\s*/, '').split(' a ')[0],
        end: this.formatSlotForUser(slot.start, slot.end, index).includes(' a ') ? this.formatSlotForUser(slot.start, slot.end, index).split(' a ')[1] : null,
        mode,
      })),
      displayBlocks: [
        { type: 'paragraph', text: `Tengo estos horarios disponibles para agendar la ${serviceLabel}. Responde con el número del horario que prefieres.`, items: [] },
        { type: 'numbered_list', text: null, items: slots.map((slot, index) => this.formatSlotForUser(slot.start, slot.end, index).replace(/^\d+[.)]\s*/, '')) },
      ],
      actionUxWarnings: Array.from(new Set([...(Array.isArray(payload?.actionUxWarnings) ? payload.actionUxWarnings : []), 'scheduled_slots_forced'])).slice(0, 12),
      actionUxRepaired: true,
    };
  }

  private forceSchedulingChoicePrompt(payload: any, state: AiChatTurnState) {
    const mode = /chat/i.test(String(payload?.recommendedService || '')) ? 'chat' : 'video';
    if (!state.schedulingStage) {
      return {
        ...payload,
        message: 'Perfecto. ¿Para cuándo quieres agendar la consulta?',
        nextStep: 'interview',
        recommendedService: null,
        actionLabel: 'Elegir fecha',
        intakeQuestions: [],
        commerceRecommendation: 'included',
        schedulingStage: 'date_range',
        schedulingMode: mode,
        schedulingOptions: [
          { label: 'Hoy', value: 'today', mode },
          { label: 'Esta semana', value: 'this_week', mode },
          { label: 'La próxima semana', value: 'next_week', mode },
        ],
        displayBlocks: [{ type: 'paragraph', text: 'Perfecto. ¿Para cuándo quieres agendar la consulta?', items: [] }],
      };
    }
    if (state.schedulingStage === 'date_range') {
      return {
        ...payload,
        message: 'Bien. ¿Qué horario te funciona mejor?',
        nextStep: 'interview',
        recommendedService: null,
        actionLabel: 'Elegir horario',
        intakeQuestions: [],
        commerceRecommendation: 'included',
        schedulingStage: 'daypart',
        schedulingMode: mode,
        schedulingRange: state.schedulingRange,
        schedulingOptions: [
          { label: 'Mañana', value: 'morning', mode },
          { label: 'Tarde', value: 'afternoon', mode },
          { label: 'Noche', value: 'evening', mode },
        ],
        displayBlocks: [{ type: 'paragraph', text: 'Bien. ¿Qué horario te funciona mejor?', items: [] }],
      };
    }
    return null;
  }

  private fallbackCommerceRecommendation(serviceAccess: any) {
    if (!serviceAccess) return null;
    if (serviceAccess.canUse === true) return 'included';
    return serviceAccess.reason === 'no_active_subscription' ? 'upgrade_plan' : 'one_off';
  }

  private fallbackActionLabel(serviceType: string, canUse: boolean | null | undefined) {
    if (canUse === true) return serviceType === 'video' ? 'Iniciar video' : 'Iniciar chat';
    return serviceType === 'video' ? 'Comprar video único' : 'Comprar chat único';
  }

  private normalizeChatNextStep(value: unknown): AiChatNextStep | null {
    const normalized = String(value || '').trim().toLowerCase();
    if (normalized === 'interview' || normalized === 'recommendation' || normalized === 'activation' || normalized === 'handoff' || normalized === 'payment') {
      return normalized;
    }
    return null;
  }

  private inferChatNextStep(payload: any, urgentIntake: boolean, questions: string[]): AiChatNextStep {
    const explicit = this.normalizeChatNextStep(payload?.nextStep);
    if (urgentIntake && questions.length) return 'interview';
    const commerce = String(payload?.commerceRecommendation || '').toLowerCase();
    if (commerce === 'one_off' || commerce === 'upgrade_plan') return 'payment';
    if (payload?.recommendedService) return 'recommendation';
    return explicit || 'interview';
  }

  private normalizeChatActionState(payload: any, urgentIntake: boolean, questions: string[]) {
    const warnings = new Set<string>();
    const nextStep = this.inferChatNextStep(payload, urgentIntake, questions);
    payload.nextStep = nextStep;
    if (nextStep === 'interview') {
      if (payload.recommendedService) warnings.add('interview_recommended_service_removed');
      payload.recommendedService = null;
      if (!payload.actionLabel || /chat|video|agendar|iniciar|comprar|plan/i.test(String(payload.actionLabel))) {
        warnings.add('interview_action_label_reset');
        payload.actionLabel = questions.length ? 'Responder preguntas de urgencia' : 'Responder en el chat';
      }
      if (payload.commerceRecommendation !== 'none') {
        if (payload.commerceRecommendation && payload.commerceRecommendation !== 'ask_more') warnings.add('interview_commerce_reset');
        payload.commerceRecommendation = 'ask_more';
      }
    }
    if ((nextStep === 'recommendation' || nextStep === 'payment') && questions.length) {
      warnings.add('action_turn_intake_questions_removed');
      payload.intakeQuestions = [];
    }
    const existingWarnings = Array.isArray(payload.actionUxWarnings)
      ? payload.actionUxWarnings.map((warning: any) => String(warning || '').trim()).filter(Boolean)
      : [];
    payload.actionUxWarnings = Array.from(new Set([...existingWarnings, ...warnings])).slice(0, 12);
    payload.actionUxRepaired = payload.actionUxWarnings.length > 0;
    return payload;
  }

  private cleanChatDisplayText(value: unknown) {
    return String(value ?? '')
      .replace(/\r\n?/g, '\n')
      .replace(/\*\*/g, '')
      .replace(/__/g, '')
      .replace(/`/g, '')
      .replace(/^\s{0,3}#{1,6}\s+/gm, '')
      .replace(/[ \t]+\n/g, '\n')
      .replace(/\n[ \t]+/g, '\n')
      .replace(/[ \t]{2,}/g, ' ')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }

  private cleanChatBlockText(value: unknown) {
    return this.cleanChatDisplayText(value).replace(/\s+/g, ' ').trim();
  }

  private cleanChatListItem(value: unknown) {
    return this.cleanChatBlockText(value)
      .replace(/^(?:(?:\d{1,2}[.)])|[-*\u2022])\s+/, '')
      .trim();
  }

  private isChatDisplayBlockType(value: string): value is AiChatDisplayBlockType {
    return value === 'paragraph' || value === 'numbered_list' || value === 'bullet_list' || value === 'safety_note';
  }

  private uniqueChatListItems(items: string[]) {
    const seen = new Set<string>();
    const out: string[] = [];
    for (const item of items) {
      const cleaned = this.cleanChatListItem(item);
      if (!cleaned) continue;
      const key = this.normalizeCareText(cleaned).replace(/[^a-z0-9]+/g, '');
      if (!key || seen.has(key)) continue;
      seen.add(key);
      out.push(cleaned);
    }
    return out;
  }

  private chatIntroBeforeList(text: string) {
    const cleaned = this.cleanChatDisplayText(text);
    const markers = [
      cleaned.search(/(^|\s)\d{1,2}[.)]\s+/),
      cleaned.search(/(^|\n)\s*[-*\u2022]\s+/),
    ].filter((index) => index >= 0);
    if (!markers.length) return cleaned;
    return cleaned.slice(0, Math.min(...markers)).replace(/[:：]\s*$/, '.').trim();
  }

  private extractNumberedItems(text: string) {
    const cleaned = this.cleanChatDisplayText(text);
    const marker = cleaned.search(/(^|\s)\d{1,2}[.)]\s+/);
    if (marker < 0) return { intro: cleaned, items: [] as string[] };
    const intro = cleaned.slice(0, marker).replace(/[:：]\s*$/, '.').trim();
    const listText = cleaned.slice(marker).trim();
    const items: string[] = [];
    const itemPattern = /\d{1,2}[.)]\s+([\s\S]*?)(?=(?:\s+\d{1,2}[.)]\s+)|$)/g;
    for (const match of listText.matchAll(itemPattern)) {
      const item = this.cleanChatListItem(match[1]);
      if (item) items.push(item);
    }
    return { intro, items: this.uniqueChatListItems(items) };
  }

  private extractBulletItems(text: string) {
    const cleaned = this.cleanChatDisplayText(text);
    const marker = cleaned.search(/(^|\n)\s*[-*\u2022]\s+/);
    if (marker < 0) return { intro: cleaned, items: [] as string[] };
    const intro = cleaned.slice(0, marker).replace(/[:：]\s*$/, '.').trim();
    const listText = cleaned.slice(marker).trim();
    const items = listText
      .split(/\n+/)
      .map((line) => /^\s*[-*\u2022]\s+(.+)$/.exec(line)?.[1] || '')
      .map((item) => this.cleanChatListItem(item))
      .filter(Boolean);
    return { intro, items: this.uniqueChatListItems(items) };
  }

  private normalizeChatQuestions(value: unknown) {
    return this.uniqueChatListItems(Array.isArray(value) ? value.map((item) => String(item || '')) : []).slice(0, 3);
  }

  private normalizeExistingDisplayBlocks(value: unknown, warnings: Set<string>) {
    if (!Array.isArray(value)) {
      warnings.add('display_blocks_missing');
      return [] as AiChatDisplayBlock[];
    }
    const blocks: AiChatDisplayBlock[] = [];
    if (value.length > 6) warnings.add('display_blocks_capped');
    for (const rawBlock of value.slice(0, 6)) {
      if (!rawBlock || typeof rawBlock !== 'object' || Array.isArray(rawBlock)) {
        warnings.add('display_block_invalid');
        continue;
      }
      const block = rawBlock as Record<string, any>;
      const type = String(block.type || '').trim();
      if (!this.isChatDisplayBlockType(type)) {
        warnings.add('display_block_type_invalid');
        continue;
      }
      if (type === 'numbered_list' || type === 'bullet_list') {
        let items = this.uniqueChatListItems(Array.isArray(block.items) ? block.items.map((item) => String(item || '')) : []);
        if (!items.length && block.text) {
          const parsed = type === 'numbered_list' ? this.extractNumberedItems(String(block.text)) : this.extractBulletItems(String(block.text));
          items = parsed.items;
        }
        if (!items.length) {
          warnings.add('display_list_empty');
          continue;
        }
        if (items.length > 5) warnings.add('display_list_items_capped');
        blocks.push({ type, text: null, items: items.slice(0, 5) });
        continue;
      }
      const text = this.cleanChatBlockText(block.text);
      if (!text) {
        warnings.add('display_text_empty');
        continue;
      }
      blocks.push({ type, text, items: [] });
    }
    return blocks;
  }

  private deriveChatDisplayBlocks(message: unknown, questions: string[], warnings: Set<string>) {
    const cleanedMessage = this.cleanChatDisplayText(message);
    if (questions.length) {
      const intro = this.cleanChatBlockText(this.chatIntroBeforeList(cleanedMessage)) || 'Para valorar urgencia y dejarle buen contexto al veterinario, respóndeme rápido:';
      warnings.add('display_blocks_derived_from_intake_questions');
      return [
        { type: 'paragraph', text: intro, items: [] },
        { type: 'numbered_list', text: null, items: questions },
      ] as AiChatDisplayBlock[];
    }

    const numbered = this.extractNumberedItems(cleanedMessage);
    if (numbered.items.length >= 2) {
      warnings.add('display_blocks_derived_from_numbered_text');
      return [
        ...(numbered.intro ? [{ type: 'paragraph' as const, text: this.cleanChatBlockText(numbered.intro), items: [] as string[] }] : []),
        { type: 'numbered_list' as const, text: null, items: numbered.items.slice(0, 5) },
      ];
    }

    const bullets = this.extractBulletItems(cleanedMessage);
    if (bullets.items.length >= 2) {
      warnings.add('display_blocks_derived_from_bullet_text');
      return [
        ...(bullets.intro ? [{ type: 'paragraph' as const, text: this.cleanChatBlockText(bullets.intro), items: [] as string[] }] : []),
        { type: 'bullet_list' as const, text: null, items: bullets.items.slice(0, 5) },
      ];
    }

    const paragraphs = cleanedMessage
      .split(/\n{2,}|\n/)
      .map((paragraph) => this.cleanChatBlockText(paragraph))
      .filter(Boolean)
      .slice(0, 4);
    if (paragraphs.length > 1) warnings.add('display_blocks_derived_from_paragraphs');
    return (paragraphs.length ? paragraphs : ['Claro, puedo ayudarte.'])
      .map((text) => ({ type: 'paragraph' as const, text, items: [] as string[] }));
  }

  private enforceUrgentQuestionBlock(blocks: AiChatDisplayBlock[], questions: string[], payload: any, warnings: Set<string>) {
    if (!questions.length) return blocks;
    const firstTextBlock = blocks.find((block) => (block.type === 'paragraph' || block.type === 'safety_note') && block.text)?.text;
    const intro = this.cleanChatBlockText(this.chatIntroBeforeList(firstTextBlock || payload?.message || ''))
      || 'Para valorar urgencia y dejarle buen contexto al veterinario, respóndeme rápido:';
    warnings.add('urgent_questions_normalized');
    return [
      { type: 'paragraph', text: intro, items: [] },
      { type: 'numbered_list', text: null, items: questions },
    ] as AiChatDisplayBlock[];
  }

  private composeChatFallbackMessage(blocks: AiChatDisplayBlock[]) {
    const lines: string[] = [];
    for (const block of blocks) {
      if (block.type === 'numbered_list') {
        block.items.forEach((item, index) => lines.push(`${index + 1}. ${item}`));
      } else if (block.type === 'bullet_list') {
        block.items.forEach((item) => lines.push(`- ${item}`));
      } else if (block.text) {
        lines.push(block.text);
      }
    }
    return lines.join('\n').replace(/\n{3,}/g, '\n\n').trim();
  }

  private removeInterviewBlocksForActionTurn(blocks: AiChatDisplayBlock[], fallbackText: string, warnings: Set<string>) {
    const filtered = blocks.filter((block) => block.type !== 'numbered_list');
    if (filtered.length !== blocks.length) warnings.add('action_turn_removed_intake_list');
    if (filtered.length) return filtered;
    warnings.add('action_turn_fallback_paragraph');
    const fallback = this.cleanChatBlockText(this.chatIntroBeforeList(fallbackText)) || this.cleanChatBlockText(fallbackText);
    return fallback ? [{ type: 'paragraph', text: fallback, items: [] }] as AiChatDisplayBlock[] : [];
  }

  private normalizeChatDisplayPayload(payload: any, urgentIntake: boolean) {
    const warnings = new Set<string>();
    const originalMessage = this.cleanChatDisplayText(payload?.message);
    const questions = this.normalizeChatQuestions(payload?.intakeQuestions);
    if (Array.isArray(payload?.intakeQuestions) && questions.length !== payload.intakeQuestions.length) {
      warnings.add('intake_questions_normalized');
    }
    let blocks = this.normalizeExistingDisplayBlocks(payload?.displayBlocks, warnings);
    if (!blocks.length) blocks = this.deriveChatDisplayBlocks(originalMessage, questions, warnings);
    if (urgentIntake && questions.length) blocks = this.enforceUrgentQuestionBlock(blocks, questions, payload, warnings);
    const nextStep = this.normalizeChatNextStep(payload?.nextStep);
    if (nextStep === 'recommendation' || nextStep === 'payment') {
      blocks = this.removeInterviewBlocksForActionTurn(blocks, originalMessage, warnings);
      payload.intakeQuestions = [];
    }
    if (blocks.length > 6) {
      warnings.add('display_blocks_capped');
      blocks = blocks.slice(0, 6);
    }
    const message = this.composeChatFallbackMessage(blocks) || originalMessage || 'Claro, puedo ayudarte.';
    const originalComparable = originalMessage.replace(/\s+/g, ' ').trim();
    const messageComparable = message.replace(/\s+/g, ' ').trim();
    if (originalComparable && originalComparable !== messageComparable) warnings.add('message_regenerated_from_display_blocks');
    payload.formatVersion = 1;
    payload.displayBlocks = blocks;
    payload.message = message;
    payload.intakeQuestions = (nextStep === 'recommendation' || nextStep === 'payment') ? [] : questions;
    payload.formattingRepaired = warnings.size > 0;
    payload.formattingWarnings = Array.from(warnings).slice(0, 12);
    const actionWarnings = Array.isArray(payload.actionUxWarnings)
      ? payload.actionUxWarnings.map((warning: any) => String(warning || '').trim()).filter(Boolean)
      : [];
    for (const warning of payload.formattingWarnings) {
      if (String(warning).startsWith('action_turn_')) actionWarnings.push(String(warning));
    }
    payload.actionUxWarnings = Array.from(new Set(actionWarnings)).slice(0, 12);
    payload.actionUxRepaired = payload.actionUxWarnings.length > 0;
    return payload;
  }

  private normalizeChatTurnPayload(payload: any, context: AiChatTurnContext, latestMessage: string, state: AiChatTurnState, toolResults: Array<{ name: string; output: any }> = []) {
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return payload;
    const normalized = { ...payload };
    const scheduledAppointmentCreated = toolResults.some((result) => result.name === 'schedule_video' || result.name === 'schedule_chat');
    if (state.wantsScheduling && !scheduledAppointmentCreated) {
      const choicePrompt = this.forceSchedulingChoicePrompt(normalized, state);
      if (choicePrompt) return this.normalizeChatDisplayPayload(choicePrompt, false);
      const slotOffer = this.forceSchedulingSlotOffer(normalized, toolResults);
      if (slotOffer) return this.normalizeChatDisplayPayload(slotOffer, false);
    }
    if (this.isGenericVetRequest(latestMessage)) {
      normalized.nextStep = 'interview';
      normalized.urgency = 'routine';
      normalized.safetyEscalation = false;
      normalized.recommendedService = null;
      normalized.actionLabel = null;
      normalized.intakeQuestions = [];
      normalized.caseSummary = null;
      normalized.handoffSummary = null;
      normalized.routingRationale = null;
      normalized.commerceRecommendation = 'ask_more';
      const message = String(normalized.message || '').trim();
      if (!message || this.hasClinicalSignal(message)) {
        normalized.message = 'Claro, puedo ayudarte a contactar a un veterinario. Cuéntame brevemente qué necesitas hoy y si prefieres seguir por chat o videollamada.';
      }
      return this.normalizeChatDisplayPayload(normalized, false);
    }
    const urgentIntake = this.shouldAskUrgentIntake(normalized, latestMessage, state);
    const existingQuestions = Array.isArray(normalized.intakeQuestions)
      ? normalized.intakeQuestions.map((question: any) => String(question || '').trim()).filter(Boolean).slice(0, 3)
      : [];
    const questions: string[] = urgentIntake && existingQuestions.length < 2
      ? this.urgentIntakeQuestions(context)
      : existingQuestions;

    normalized.intakeQuestions = questions;
    if (urgentIntake) {
      const message = String(normalized.message || '').trim();
      const questionCount = (message.match(/\?/g) || []).length;
      if (questionCount < 2 && questions.length >= 2) {
        normalized.message = [
          message || 'Esto puede requerir valoración veterinaria hoy.',
          'Para valorar urgencia y dejarle buen contexto al veterinario, respóndeme rápido:',
          ...questions.map((question: string, index: number) => `${index + 1}. ${question}`),
        ].join('\n');
      }
      if (!normalized.actionLabel || /resumen/i.test(String(normalized.actionLabel))) {
        normalized.actionLabel = 'Responder preguntas de urgencia';
      }
    } else if (state.afterUrgentIntakeAnswer) {
      normalized.intakeQuestions = [];
      if (!normalized.recommendedService && !normalized.actionLabel) {
        normalized.actionLabel = 'Ver opciones de atención';
      }
    }
    const serviceAccess = this.latestServiceAccessToolResult(toolResults);
    if ((state.explicitCareRequest || state.wantsScheduling) && serviceAccess) {
      const serviceType = String(serviceAccess.serviceType || '').toLowerCase();
      if ((serviceType === 'chat' || serviceType === 'video') && !normalized.recommendedService) {
        normalized.recommendedService = state.wantsScheduling ? `scheduled_${serviceType}` : serviceType;
      }
      if ((serviceType === 'chat' || serviceType === 'video') && !normalized.actionLabel) {
        normalized.actionLabel = state.wantsScheduling && serviceAccess.canUse === true
          ? (serviceType === 'video' ? 'Agendar video' : 'Agendar chat')
          : this.fallbackActionLabel(serviceType, serviceAccess.canUse === true);
      }
      if (!normalized.commerceRecommendation) {
        normalized.commerceRecommendation = this.fallbackCommerceRecommendation(serviceAccess);
      }
    }
    if (state.caseDetailSignal && !normalized.caseSummary) {
      normalized.caseSummary = latestMessage.slice(0, 240);
    }
    if (state.caseDetailSignal && !normalized.handoffSummary) {
      normalized.handoffSummary = latestMessage.slice(0, 360);
    }
    this.normalizeChatActionState(normalized, urgentIntake, questions);
    return this.normalizeChatDisplayPayload(normalized, urgentIntake);
  }

  private async findVetsTool(args: Record<string, any>) {
    const specialtyId = this.normalizeOptionalUuid(String(args.specialtyId || ''), 'specialtyId');
    const limit = Math.min(Math.max(Number(args.limit || 3) || 3, 1), 5);
    const { rows } = await this.db.query<any>(
      `select v.id,
              u.full_name,
              v.bio,
              v.years_experience,
              coalesce(v.languages, '{}'::text[]) as languages,
              av.next_available_at,
              coalesce(av.available_slots_next_7d, 0)::int as available_slots_next_7d,
              coalesce(avg(r.score)::numeric(10,2), 0) as rating_average,
              count(r.id)::int as rating_count,
              (select count(*)::int
                 from chat_sessions s
                where s.vet_id = v.id
                  and s.status = 'active') as active_consults
         from vets v
         join users u on u.id = v.id
         left join ratings r on r.vet_id = v.id
    left join lateral (
              with params as (
                select now() as since,
                       now() + interval '7 days' as until,
                       30::int as dur
              ),
              days as (
                select generate_series(date_trunc('day', (select since from params)), date_trunc('day', (select until from params)), interval '1 day')::date as day
              ),
              avail as (
                select d.day,
                       va.start_time as start_t,
                       va.end_time as end_t
                  from days d
                  join vet_availability va on va.weekday = extract(dow from d.day) and va.vet_id = v.id
              ),
              ranges as (
                select make_timestamptz(extract(year from a.day)::int, extract(month from a.day)::int, extract(day from a.day)::int, extract(hour from a.start_t)::int, extract(minute from a.start_t)::int, 0) as start_at,
                       make_timestamptz(extract(year from a.day)::int, extract(month from a.day)::int, extract(day from a.day)::int, extract(hour from a.end_t)::int, extract(minute from a.end_t)::int, 0) as end_at
                  from avail a
              ),
              slots as (
                select gs as slot_start, gs + make_interval(mins => (select dur from params)) as slot_end
                  from ranges r,
                       generate_series(r.start_at, r.end_at - make_interval(mins => (select dur from params)), make_interval(mins => (select dur from params))) as gs
              ),
              booked as (
                select tstzrange(starts_at, ends_at) as appt_range
                  from appointments
                 where vet_id = v.id
                   and status = any(array['scheduled','active','confirmed']::text[])
              )
              select min(s.slot_start) as next_available_at,
                     count(*)::int as available_slots_next_7d
                from slots s
               where s.slot_start >= (select since from params)
                 and s.slot_end <= (select until from params)
                 and not exists (select 1 from booked b where tstzrange(s.slot_start, s.slot_end) && b.appt_range)
            ) av on true
        where v.is_approved = true
          and not exists (
            select 1
              from vet_consult_locks vcl
             where vcl.vet_id = v.id
               and vcl.released_at is null
               and vcl.expires_at > now()
          )
          and ($1::uuid is null or (
            array_position(v.specialties, $1::uuid) is not null
            and exists (select 1 from vet_specialties vs where vs.id = $1::uuid and coalesce(vs.is_active, true))
          ))
        group by v.id, u.full_name, v.bio, v.years_experience, v.languages, av.next_available_at, av.available_slots_next_7d
        order by active_consults asc, (av.next_available_at is null) asc, av.next_available_at asc, count(r.id) desc, coalesce(avg(r.score), 0) desc, u.full_name asc
        limit $2`,
      [specialtyId, limit]
    );
    return { ok: true, specialtyId, vets: rows };
  }

  private async checkServiceAccessTool(args: Record<string, any>, context: AiChatTurnContext) {
    const serviceType = String(args.serviceType || '').trim().toLowerCase();
    if (serviceType !== 'chat' && serviceType !== 'video') throw new BadRequestException('serviceType_invalid');
    return this.entitlements.checkServiceAccessForUser(context.actorUserId, serviceType as EntitlementKind);
  }

  private async getAvailableSlotsTool(args: Record<string, any>) {
    const durationMin = Math.min(Math.max(Number(args.durationMin || 30) || 30, 10), 240);
    const since = args.since ? new Date(String(args.since)) : new Date();
    const until = args.until ? new Date(String(args.until)) : new Date(since.getTime() + 7 * 24 * 60 * 60 * 1000);
    if (Number.isNaN(since.getTime()) || Number.isNaN(until.getTime()) || until <= since) {
      throw new BadRequestException('slot_window_invalid');
    }
    const vetId = String(args.vetId || '').trim();
    const slots = await this.appointmentScheduling.availableSlots({
      vetId,
      since: since.toISOString(),
      until: until.toISOString(),
      durationMin,
      limit: 5,
    });
    return { ok: true, vetId, durationMin, slots };
  }

  private async scheduleVideoTool(args: Record<string, any>) {
    return this.scheduleAppointmentTool(args, 'video');
  }

  private async scheduleChatTool(args: Record<string, any>) {
    return this.scheduleAppointmentTool(args, 'chat');
  }

  private async scheduleAppointmentTool(args: Record<string, any>, mode: 'chat' | 'video') {
    const confirmationToken = String(args.confirmationToken || '').trim();
    if (!confirmationToken) throw new BadRequestException('slot_confirmation_required');
    const appointment = await this.appointmentScheduling.createScheduledConsult({
      vetId: String(args.vetId || '').trim(),
      petId: args.petId == null ? null : String(args.petId || '').trim(),
      specialtyId: String(args.specialtyId || '').trim(),
      startsAt: String(args.startsAt || '').trim(),
      durationMin: args.durationMin == null ? null : Number(args.durationMin),
      priority: 'routine',
      mode,
    });
    return { ok: true, appointment };
  }

  private async executeChatTool(call: AiChatToolCall, context: AiChatTurnContext) {
    const args = this.parseToolArguments(call.arguments);
    switch (call.name) {
      case 'recommend_specialty':
        return this.recommendSpecialtyTool(args, context);
      case 'find_vets':
        return this.findVetsTool(args);
      case 'check_service_access':
        return this.checkServiceAccessTool(args, context);
      case 'get_available_slots':
        return this.getAvailableSlotsTool(args);
      case 'schedule_video':
        return this.scheduleVideoTool(args);
      case 'schedule_chat':
        return this.scheduleChatTool(args);
      default:
        throw new BadGatewayException(`ai_tool_not_allowed:${call.name}`);
    }
  }

  private chatTurnDryRun(context: AiChatTurnContext, message: string) {
    const wantsVideo = /video|videollamada|llamada|urgente|urgent|emergency/i.test(message);
    const petNames = context.pets.map((pet) => pet?.name).filter(Boolean).slice(0, 3);
    const hasMultiplePets = context.pets.length > 1;
    const assistantMessage = wantsVideo
      ? `Puedo ayudarte a preparar esto para un veterinario. ${hasMultiplePets ? `¿Para cuál caballo es: ${petNames.join(', ')}? ` : ''}Por lo que describes, puede convenir una videollamada para valorar urgencia.`
      : `Claro, te ayudo. ${hasMultiplePets ? `¿Para cuál caballo es: ${petNames.join(', ')}? ` : 'Cuéntame desde cuándo pasa y si ha cambiado su apetito, agua o energía. '}Con eso puedo orientar mejor si conviene chat, videollamada inmediata o agendar una videollamada.`;
    return {
      ok: true,
      dryRun: true,
      provider: 'dry_run',
      model: this.providerConfig(undefined, true).model,
      responseId: null,
      payload: {
        message: assistantMessage,
        formatVersion: 1,
        nextStep: wantsVideo ? 'recommendation' : 'interview',
        displayBlocks: [{ type: wantsVideo ? 'safety_note' : 'paragraph', text: assistantMessage, items: [] }],
        urgency: wantsVideo ? 'urgent' : 'routine',
        recommendedService: wantsVideo ? 'video' : null,
        actionLabel: wantsVideo ? 'buscar videollamada' : 'buscar veterinario',
        safetyEscalation: wantsVideo,
        intakeQuestions: [],
        caseSummary: message ? message.slice(0, 240) : null,
        handoffSummary: message ? message.slice(0, 360) : null,
        routingRationale: 'Respuesta determinística de dry-run para pruebas sin proveedor de IA.',
        commerceRecommendation: 'ask_more',
      },
      toolResults: [],
      context,
    };
  }

  private isRecoverableChatTurnError(error: any) {
    if (error instanceof BadGatewayException || error instanceof GatewayTimeoutException) return true;
    const name = String(error?.name || '').toLowerCase();
    const message = String(error?.message || error || '').toLowerCase();
    return name.includes('abort') ||
      message.includes('timeout') ||
      message.includes('aborted') ||
      message.includes('fetch failed') ||
      message.includes('ai_provider') ||
      message.includes('ai_chat_provider');
  }

  private async chatTurnFallback(input: AiChatTurnInput, context: AiChatTurnContext, error: any) {
    const messages = this.normalizeChatMessages(input);
    const latestMessage = messages[messages.length - 1]?.content || '';
    const state = this.chatTurnState(messages);
    const toolResults: Array<{ name: string; output: any }> = [];
    const providerError = String(error?.message || error || 'ai_chat_provider_unavailable').slice(0, 240);
    const shouldRoute = state.caseDetailSignal || state.explicitCareRequest;

    if (shouldRoute) {
      const specialty = await this.recommendSpecialtyTool({ symptoms: latestMessage, petId: context.petId }, context);
      toolResults.push({ name: 'recommend_specialty', output: specialty });

      const specialtyId = specialty?.specialty?.id || null;
      if (specialtyId) {
        const vets = await this.findVetsTool({ specialtyId, limit: 3 });
        toolResults.push({ name: 'find_vets', output: vets });
      }

      const serviceType = state.explicitCareRequest || /urgente|dolor|cojea|renquea|renguea|no se levanta|respira/.test(this.normalizeCareText(latestMessage))
        ? 'video'
        : 'chat';
      const access = await this.checkServiceAccessTool({ serviceType }, context);
      toolResults.push({ name: 'check_service_access', output: access });
    }

    const serviceAccess = this.latestServiceAccessToolResult(toolResults);
    const serviceType = String(serviceAccess?.serviceType || (shouldRoute ? 'video' : 'chat')).toLowerCase();
    const questions = shouldRoute ? this.fallbackIntakeQuestions(latestMessage, context) : [];
    const fallbackIntro = shouldRoute
      ? 'Lo siento, eso puede requerir revisión pronto. Para orientarte rápido con el veterinario adecuado, respóndeme por favor estas 3 cosas:'
      : 'Claro, puedo ayudarte. Cuéntame brevemente qué necesitas y si prefieres seguir por chat o videollamada.';
    const payload = this.normalizeChatTurnPayload({
      message: shouldRoute
        ? [
            fallbackIntro,
            ...questions.map((question, index) => `${index + 1}. ${question}`),
          ].join('\n')
        : fallbackIntro,
      formatVersion: 1,
      nextStep: 'interview',
      displayBlocks: shouldRoute
        ? [
            { type: 'paragraph', text: fallbackIntro, items: [] },
            { type: 'numbered_list', text: null, items: questions },
          ]
        : [{ type: 'paragraph', text: fallbackIntro, items: [] }],
      urgency: shouldRoute ? 'urgent' : 'routine',
      recommendedService: null,
      actionLabel: shouldRoute ? 'Responder preguntas de urgencia' : null,
      safetyEscalation: shouldRoute,
      intakeQuestions: questions,
      caseSummary: shouldRoute ? latestMessage.slice(0, 240) : null,
      handoffSummary: shouldRoute ? latestMessage.slice(0, 360) : null,
      routingRationale: shouldRoute ? 'Respuesta de respaldo por indisponibilidad temporal del proveedor de IA.' : null,
      commerceRecommendation: serviceAccess ? this.fallbackCommerceRecommendation(serviceAccess) : 'ask_more',
    }, context, latestMessage, state, toolResults);

    return {
      ok: true,
      provider: 'fallback',
      model: 'deterministic-chat-turn-fallback',
      responseId: null,
      payload,
      toolResults,
      context,
      fallback: true,
      fallbackReason: providerError,
    };
  }

  private chatTurnFunctionCallInput(call: AiChatToolCall) {
    return {
      type: 'function_call',
      call_id: call.call_id,
      name: call.name,
      arguments: typeof call.arguments === 'string' ? call.arguments : JSON.stringify(call.arguments || {}),
    };
  }

  private chatFormattingEventMetadata(payload: any) {
    const blocks = Array.isArray(payload?.displayBlocks) ? payload.displayBlocks : [];
    const blockTypes = blocks
      .map((block: any) => String(block?.type || '').trim())
      .filter(Boolean)
      .slice(0, 12);
    const listItemCount = blocks.reduce((count: number, block: any) => {
      const items = Array.isArray(block?.items) ? block.items : [];
      return count + items.length;
    }, 0);
    const warnings = Array.isArray(payload?.formattingWarnings)
      ? payload.formattingWarnings.map((warning: any) => String(warning || '').trim()).filter(Boolean).slice(0, 12)
      : [];
    return {
      formatVersion: Number(payload?.formatVersion || 0) || null,
      hasDisplayBlocks: blocks.length > 0,
      blockCount: blocks.length,
      blockTypes,
      listItemCount,
      messageLength: String(payload?.message || '').length,
      formattingRepaired: payload?.formattingRepaired === true,
      formattingWarnings: warnings,
    };
  }

  private chatActionUxEventMetadata(payload: any) {
    const nextStep = this.normalizeChatNextStep(payload?.nextStep);
    const intakeQuestions = Array.isArray(payload?.intakeQuestions) ? payload.intakeQuestions : [];
    const recommendedService = String(payload?.recommendedService || '').trim() || null;
    const commerceRecommendation = String(payload?.commerceRecommendation || '').trim() || null;
    const warnings = Array.isArray(payload?.actionUxWarnings)
      ? payload.actionUxWarnings.map((warning: any) => String(warning || '').trim()).filter(Boolean).slice(0, 12)
      : [];
    const mixedQuestionActionState = intakeQuestions.length > 0 && !!recommendedService;
    return {
      nextStep: nextStep || null,
      recommendedService,
      commerceRecommendation,
      intakeQuestionCount: intakeQuestions.length,
      canShowActions: nextStep !== 'interview' && intakeQuestions.length === 0 && (!!recommendedService || commerceRecommendation === 'one_off' || commerceRecommendation === 'upgrade_plan'),
      mixedQuestionActionState,
      actionUxRepaired: payload?.actionUxRepaired === true || warnings.length > 0,
      actionUxWarnings: warnings,
    };
  }

  private async callChatTurnProvider(input: AiChatTurnInput, context: AiChatTurnContext) {
    const cfg = this.providerConfig(undefined, !!input.dryRun);
    const messages = this.normalizeChatMessages(input);
    const latestMessage = messages[messages.length - 1]?.content || '';
    const state = this.chatTurnState(messages);
    if (input.dryRun) return this.chatTurnDryRun(context, latestMessage);
    if (!cfg.apiKey) throw new ServiceUnavailableException('ai_provider_not_configured');
    if (cfg.apiMode !== 'responses') throw new ServiceUnavailableException('ai_chat_turn_requires_responses_api');
    if (!messages.length) throw new BadRequestException('message_required');

    const responseInput: any[] = messages.map((message) => ({ role: message.role, content: message.content }));
    const toolResults: Array<{ name: string; output: any }> = [];
    const tools = this.chatTurnTools();

    for (let step = 0; step < 6; step += 1) {
      const hasSpecialty = toolResults.some((result) => result.name === 'recommend_specialty');
      const hasVets = toolResults.some((result) => result.name === 'find_vets');
      const hasAccess = toolResults.some((result) => result.name === 'check_service_access');
      const hasSlots = toolResults.some((result) => result.name === 'get_available_slots');
      const hasScheduledAppointment = toolResults.some((result) => result.name === 'schedule_video' || result.name === 'schedule_chat');
      const serviceAccess = this.latestServiceAccessToolResult(toolResults);
      const accessExhausted = serviceAccess && serviceAccess.canUse === false;
      const needsSchedulingTools = state.wantsScheduling && state.schedulingStage === 'daypart' && !hasScheduledAppointment && (!hasSpecialty || !hasVets || !hasAccess || (!accessExhausted && !hasSlots));
      const needsRoutingTools = state.afterUrgentIntakeAnswer
        ? (!hasSpecialty || !hasVets)
        : (state.explicitCareRequest && (!hasSpecialty || !hasVets || !hasAccess)) || needsSchedulingTools;
      const body: Record<string, any> = {
        model: cfg.model,
        store: false,
        instructions: this.chatTurnInstructions(context, state),
        input: responseInput,
        tools,
        text: { format: this.chatTurnResponseFormat() },
        tool_choice: needsRoutingTools ? 'required' : 'auto',
        parallel_tool_calls: false,
      };
      if (cfg.reasoningEffort) body.reasoning = { effort: cfg.reasoningEffort };
      const data = await this.postProviderJson(cfg, '/responses', body, 'ai_chat_provider_http');
      const output = Array.isArray(data?.output) ? data.output : [];
      const toolCalls = output.filter((item: any): item is AiChatToolCall => item?.type === 'function_call');

      if (!toolCalls.length) {
        const payload = this.normalizeChatTurnPayload(this.parseProviderPayload(this.extractResponsesText(data)), context, latestMessage, state, toolResults);
        return { ok: true, provider: cfg.provider, model: cfg.model, responseId: data?.id || null, payload, toolResults, context };
      }

      for (const toolCall of toolCalls) {
        responseInput.push(this.chatTurnFunctionCallInput(toolCall));
        const result = await this.executeChatTool(toolCall, context);
        toolResults.push({ name: toolCall.name, output: result });
        responseInput.push({
          type: 'function_call_output',
          call_id: toolCall.call_id,
          output: JSON.stringify(result),
        });
      }
    }

    throw new BadGatewayException('ai_chat_tool_loop_exceeded');
  }

  async runChatTurn(input: AiChatTurnInput) {
    const actorUserId = this.rc.requireUuidUserId();
    const petId = this.normalizeOptionalUuid(input.petId, 'petId');
    const sessionId = this.normalizeOptionalUuid(input.sessionId, 'sessionId');
    const conversationId = String(input.conversationId || '').trim() || null;
    const context = await this.buildChatTurnContext(actorUserId, petId, sessionId, conversationId);
    const requestPayload = {
      petId,
      sessionId,
      conversationId,
      messagePresent: !!String(input.message || '').trim(),
      messageCount: Array.isArray(input.messages) ? input.messages.length : 0,
      dryRun: !!input.dryRun,
      contextSummary: {
        pets: context.pets.length,
        hasSubscription: !!context.subscription,
        recentConversations: context.recentConversations.length,
      },
    };
    const eventId = await this.insertRawEvent({
      actorUserId,
      petId,
      sessionId,
      eventType: 'ai.chat_turn.run',
      featureKey: 'ai.chat_turn',
      requestPayload,
    });
    if (!eventId) throw new ServiceUnavailableException('ai_event_insert_failed');

    const startedAt = Date.now();
    try {
      const result = await this.callChatTurnProvider(input, context);
      await this.completeEvent(eventId, 'succeeded', {
        provider: result.provider,
        model: result.model,
        responsePayload: {
          payload: result.payload,
          toolResults: result.toolResults,
          responseId: result.responseId || null,
          formatting: this.chatFormattingEventMetadata(result.payload),
          actionUx: this.chatActionUxEventMetadata(result.payload),
        },
        latencyMs: Date.now() - startedAt,
      });
      return { ...result, eventId };
    } catch (e: any) {
      if (this.isRecoverableChatTurnError(e)) {
        try {
          const fallback = await this.chatTurnFallback(input, context, e);
          await this.completeEvent(eventId, 'succeeded', {
            provider: fallback.provider,
            model: fallback.model,
            responsePayload: {
              payload: fallback.payload,
              toolResults: fallback.toolResults,
              responseId: null,
              formatting: this.chatFormattingEventMetadata(fallback.payload),
              actionUx: this.chatActionUxEventMetadata(fallback.payload),
              fallback: true,
              fallbackReason: fallback.fallbackReason,
            },
            errorText: fallback.fallbackReason,
            latencyMs: Date.now() - startedAt,
          });
          return { ...fallback, eventId };
        } catch (fallbackError: any) {
          e = fallbackError || e;
        }
      }
      await this.completeEvent(eventId, 'failed', {
        errorText: (e?.message || 'ai_chat_turn_failed').slice(0, 1000),
        latencyMs: Date.now() - startedAt,
      }).catch(() => undefined);
      throw e;
    }
  }

  async generateSessionHandoff(input: AiSessionHandoffInput) {
    const actorUserId = this.rc.requireUuidUserId();
    const sessionId = this.normalizeOptionalUuid(input.sessionId, 'sessionId');
    if (!sessionId) throw new BadRequestException('sessionId_required');
    const sourceAiEventId = this.normalizeOptionalUuid(input.sourceAiEventId, 'sourceAiEventId');
    const context = await this.buildSessionHandoffContext(actorUserId, sessionId, sourceAiEventId, input.aiContext || null);
    const requestPayload = {
      sessionId,
      sourceAiEventId,
      dryRun: !!input.dryRun,
      hasAiContext: !!context.aiContext,
      sourceAiEventCount: context.sourceAiEvents.length,
    };
    const eventId = await this.insertRawEvent({
      actorUserId,
      petId: context.session.pet_id || null,
      sessionId,
      eventType: 'ai.handoff.generate',
      featureKey: 'ai.handoff',
      requestPayload,
    });
    if (!eventId) throw new ServiceUnavailableException('ai_event_insert_failed');
    this.roadmapLog('handoff.generate.started', {
      sessionId,
      eventId,
      sourceAiEventId,
      hasAiContext: !!context.aiContext,
      sourceAiEventCount: context.sourceAiEvents.length,
    });

    const startedAt = Date.now();
    try {
      const result = await this.callSessionHandoffProvider(context, !!input.dryRun);
      const payload = this.normalizeSessionHandoffPayload(result.payload, context);
      const handoff = await this.upsertSessionHandoff({ context, eventId, sourceAiEventId, payload });
      const latencyMs = Date.now() - startedAt;
      await this.completeEvent(eventId, 'succeeded', {
        provider: result.provider,
        model: result.model,
        responsePayload: { payload, responseId: result.responseId || null, handoffId: handoff?.id || null },
        latencyMs,
      });
      this.roadmapLog('handoff.generate.succeeded', {
        sessionId,
        eventId,
        handoffId: handoff?.id || null,
        provider: result.provider,
        model: result.model,
        urgency: payload.urgency,
        reportedSignCount: payload.reportedSigns.length,
        redFlagCount: payload.redFlags.length,
        answeredCount: payload.questionsAnswered.length,
        unansweredCount: payload.questionsUnanswered.length,
        firstCheckCount: payload.recommendedFirstChecks.length,
        latencyMs,
      });
      return { ok: true, provider: result.provider, model: result.model, eventId, payload, handoff };
    } catch (error: any) {
      const latencyMs = Date.now() - startedAt;
      await this.completeEvent(eventId, 'failed', {
        errorText: (error?.message || 'ai_handoff_failed').slice(0, 1000),
        latencyMs,
      }).catch(() => undefined);
      this.roadmapLog('handoff.generate.failed', {
        sessionId,
        eventId,
        error: error?.message || String(error),
        latencyMs,
      });
      throw error;
    }
  }

  async generateVideoPostCallMessage(input: AiVideoPostCallInput) {
    const actorUserId = this.rc.requireUuidUserId();
    const sessionId = this.normalizeOptionalUuid(input.sessionId, 'sessionId');
    if (!sessionId) throw new BadRequestException('sessionId_required');
    const context = await this.buildVideoPostCallContext(actorUserId, sessionId, input.endState || null);
    const eventId = await this.insertRawEvent({
      actorUserId,
      petId: context.session.pet_id || null,
      sessionId,
      eventType: 'ai.video_post_call_message.generate',
      featureKey: 'ai.video_post_call_message',
      requestPayload: {
        sessionId,
        dryRun: !!input.dryRun,
        hasHandoff: !!context.handoff,
        endReason: context.endState?.endReason || context.lifecycle?.end_reason || null,
      },
    });
    if (!eventId) throw new ServiceUnavailableException('ai_event_insert_failed');
    this.roadmapLog('video_post_call.generate.started', {
      sessionId,
      eventId,
      hasHandoff: !!context.handoff,
      endReason: context.endState?.endReason || context.lifecycle?.end_reason || null,
      rejoinEligible: context.endState?.rejoinEligible === true,
    });
    const startedAt = Date.now();
    try {
      const result = await this.callVideoPostCallProvider(context, !!input.dryRun);
      const payload = this.normalizeVideoPostCallPayload(result.payload, context);
      await this.db.runInTx(async (q) => q(
        `update video_session_lifecycle
            set post_call_message_payload = $2::jsonb,
                updated_at = now()
          where session_id = $1::uuid`,
        [sessionId, JSON.stringify({ aiEventId: eventId, payload })]
      ));
      const latencyMs = Date.now() - startedAt;
      await this.completeEvent(eventId, 'succeeded', {
        provider: result.provider,
        model: result.model,
        responsePayload: { payload, responseId: result.responseId || null },
        latencyMs,
      });
      this.roadmapLog('video_post_call.generate.succeeded', {
        sessionId,
        eventId,
        provider: result.provider,
        model: result.model,
        suggestedAction: payload.suggestedAction,
        rejoinRecommended: payload.rejoinRecommended,
        messageLength: payload.message.length,
        latencyMs,
      });
      return { provider: result.provider, model: result.model, eventId, payload };
    } catch (error: any) {
      const latencyMs = Date.now() - startedAt;
      await this.completeEvent(eventId, 'failed', {
        errorText: (error?.message || 'ai_video_post_call_failed').slice(0, 1000),
        latencyMs,
      }).catch(() => undefined);
      this.roadmapLog('video_post_call.generate.failed', {
        sessionId,
        eventId,
        error: error?.message || String(error),
        latencyMs,
      });
      throw error;
    }
  }

  private async callResponsesProvider(cfg: AiProviderConfig, prompt: PromptVersion, context: AiContext) {
    const body: Record<string, any> = {
      model: cfg.model,
      store: false,
      instructions: prompt.system_prompt,
      input: [{ role: 'user', content: this.renderPrompt(prompt.user_template, context) }],
      text: { format: this.responseFormat(prompt) },
    };
    if (cfg.reasoningEffort) body.reasoning = { effort: cfg.reasoningEffort };
    const data = await this.postProviderJson(cfg, '/responses', body, 'ai_provider_http');
    return this.parseProviderPayload(this.extractResponsesText(data));
  }

  private async callChatCompletionsProvider(cfg: AiProviderConfig, prompt: PromptVersion, context: AiContext) {
    const data = await this.postProviderJson(cfg, '/chat/completions', {
      model: cfg.model,
      store: false,
      temperature: 0.2,
      response_format: { type: 'json_object' },
      messages: [
        { role: 'system', content: prompt.system_prompt },
        { role: 'user', content: this.renderPrompt(prompt.user_template, context) },
      ],
    }, 'ai_provider_http');
    const content = data?.choices?.[0]?.message?.content;
    return this.parseProviderPayload(content);
  }

  private async callProvider(prompt: PromptVersion, context: AiContext, draftType: AiDraftType, dryRun = false) {
    const cfg = this.providerConfig(prompt, dryRun);
    if (dryRun) {
      return {
        provider: cfg.provider,
        model: cfg.model,
        payload: this.dryRunPayload(draftType, context),
      };
    }
    if (!cfg.apiKey) throw new ServiceUnavailableException('ai_provider_not_configured');
    const payload = cfg.apiMode === 'responses'
      ? await this.callResponsesProvider(cfg, prompt, context)
      : await this.callChatCompletionsProvider(cfg, prompt, context);
    return { provider: cfg.provider, model: cfg.model, payload };
  }

  private async callEmbeddingProvider(texts: string[], dimension: number, dryRun = false) {
    const cfg = this.embeddingProviderConfig(dryRun);
    if (dryRun) {
      return {
        provider: cfg.provider,
        model: cfg.model,
        embeddings: texts.map((text) => this.dryRunEmbedding(text, dimension)),
      };
    }
    if (!cfg.apiKey) throw new ServiceUnavailableException('ai_provider_not_configured');

    const data = await this.postProviderJson(cfg, '/embeddings', { model: cfg.model, input: texts }, 'ai_embedding_provider_http');
    const embeddings = Array.isArray(data?.data)
      ? data.data.map((item: any) => this.normalizeEmbedding(item?.embedding, dimension))
      : [];
    if (embeddings.length !== texts.length) throw new BadGatewayException('ai_embedding_provider_mismatched_response');
    return { provider: cfg.provider, model: cfg.model, embeddings };
  }

  private enrichReferralPayload(payload: any, context: AiContext) {
    const target = String(payload?.specialtyName || '').trim().toLowerCase();
    const specialty = context.specialties.find((item) => String(item.name || '').trim().toLowerCase() === target)
      || context.specialties.find((item) => target && String(item.name || '').trim().toLowerCase().includes(target))
      || null;
    return {
      ...payload,
      specialtyId: payload?.specialtyId || specialty?.id || null,
      specialtyName: payload?.specialtyName || specialty?.name || null,
      priority: ['routine', 'urgent'].includes(payload?.priority) ? payload.priority : 'routine',
    };
  }

  private normalizePayload(draftType: AiDraftType, payload: any, context: AiContext) {
    if (draftType === 'referral') return this.enrichReferralPayload(payload, context);
    if (draftType === 'note') {
      return {
        summaryText: String(payload?.summaryText || payload?.summary || '').slice(0, 8000),
        assessmentText: String(payload?.assessmentText || '').slice(0, 8000),
        diagnosisText: String(payload?.diagnosisText || '').slice(0, 4000),
        planSummary: String(payload?.planSummary || '').slice(0, 8000),
        followUpInstructions: String(payload?.followUpInstructions || '').slice(0, 4000),
        severity: ['low', 'medium', 'high', 'critical'].includes(payload?.severity) ? payload.severity : 'low',
      };
    }
    if (draftType === 'care_plan') {
      return {
        shortTerm: String(payload?.shortTerm || payload?.short_term || '').slice(0, 8000),
        midTerm: String(payload?.midTerm || payload?.mid_term || '').slice(0, 8000),
        longTerm: String(payload?.longTerm || payload?.long_term || '').slice(0, 8000),
        items: Array.isArray(payload?.items) ? payload.items.slice(0, 20) : [],
      };
    }
    return payload;
  }

  private async insertEvent(args: {
    context: AiContext;
    eventType: string;
    featureKey: string;
    prompt: PromptVersion;
    requestPayload: Record<string, any>;
  }) {
    const { rows } = await this.db.runInTx(async (q) => q<{ id: string }>(
      `insert into ai_events (
         id, actor_user_id, pet_id, encounter_id, session_id, event_type, feature_key,
         prompt_version_id, status, request_payload, created_at, updated_at
       ) values (
         gen_random_uuid(), $1::uuid, $2::uuid, $3::uuid, $4::uuid, $5, $6,
         $7::uuid, 'running', coalesce($8::jsonb, '{}'::jsonb), now(), now()
       ) returning id`,
      [
        args.context.actorUserId,
        args.context.petId,
        args.context.encounterId,
        args.context.sessionId,
        args.eventType,
        args.featureKey,
        args.prompt.id,
        JSON.stringify(args.requestPayload),
      ]
    ));
    return rows[0]?.id;
  }

  private async insertRawEvent(args: {
    actorUserId: string;
    petId?: string | null;
    encounterId?: string | null;
    sessionId?: string | null;
    eventType: string;
    featureKey: string;
    requestPayload: Record<string, any>;
  }) {
    const { rows } = await this.db.runInTx(async (q) => q<{ id: string }>(
      `insert into ai_events (
         id, actor_user_id, pet_id, encounter_id, session_id, event_type, feature_key, status, request_payload, created_at, updated_at
       ) values (
         gen_random_uuid(), $1::uuid, $2::uuid, $3::uuid, $4::uuid, $5, $6, 'running', coalesce($7::jsonb, '{}'::jsonb), now(), now()
       ) returning id`,
      [args.actorUserId, args.petId || null, args.encounterId || null, args.sessionId || null, args.eventType, args.featureKey, JSON.stringify(args.requestPayload)]
    ));
    return rows[0]?.id;
  }

  private async completeEvent(eventId: string, status: 'succeeded' | 'failed', args: {
    provider?: string;
    model?: string;
    responsePayload?: any;
    errorText?: string | null;
    latencyMs: number;
  }) {
    await this.db.runInTx(async (q) => q(
      `update ai_events
          set status = $2,
              provider = coalesce($3, provider),
              model = coalesce($4, model),
              response_payload = coalesce($5::jsonb, response_payload),
              error_text = $6,
              latency_ms = $7,
              updated_at = now()
        where id = $1::uuid`,
      [eventId, status, args.provider || null, args.model || null, JSON.stringify(args.responsePayload || {}), args.errorText || null, args.latencyMs]
    ));
  }

  private async insertDraft(args: {
    context: AiContext;
    eventId: string;
    prompt: PromptVersion;
    draftType: AiDraftType;
    payload: any;
  }) {
    const { rows } = await this.db.runInTx(async (q) => q<any>(
      `insert into ai_drafts (
         id, actor_user_id, pet_id, encounter_id, session_id, ai_event_id, prompt_version_id,
         draft_type, status, payload, created_at, updated_at
       ) values (
         gen_random_uuid(), $1::uuid, $2::uuid, $3::uuid, $4::uuid, $5::uuid, $6::uuid,
         $7, 'draft', coalesce($8::jsonb, '{}'::jsonb), now(), now()
       ) returning id, actor_user_id, pet_id, encounter_id, session_id, ai_event_id, prompt_version_id,
                   draft_type, status, payload, created_at, updated_at`,
      [
        args.context.actorUserId,
        args.context.petId,
        args.context.encounterId,
        args.context.sessionId,
        args.eventId,
        args.prompt.id,
        args.draftType,
        JSON.stringify(args.payload),
      ]
    ));
    return rows[0];
  }

  private async runDraft(featureKey: string, eventType: string, draftType: AiDraftType, input: AiRunInput) {
    const enabled = await this.featureEnabled(featureKey);
    if (!enabled) throw new ServiceUnavailableException('ai_feature_disabled');
    const prompt = await this.loadPrompt(featureKey);
    const context = await this.buildContext(input);
    const requestPayload = { input, contextPreview: { petId: context.petId, encounterId: context.encounterId, sessionId: context.sessionId } };
    const eventId = await this.insertEvent({ context, eventType, featureKey, prompt, requestPayload });
    if (!eventId) throw new ServiceUnavailableException('ai_event_insert_failed');

    const startedAt = Date.now();
    try {
      const providerResult = await this.callProvider(prompt, context, draftType, !!input.dryRun);
      const payload = this.normalizePayload(draftType, providerResult.payload, context);
      const latencyMs = Date.now() - startedAt;
      await this.completeEvent(eventId, 'succeeded', {
        provider: providerResult.provider,
        model: providerResult.model,
        responsePayload: payload,
        latencyMs,
      });
      const draft = await this.insertDraft({ context, eventId, prompt, draftType, payload });
      return { ok: true, eventId, draft, payload, provider: providerResult.provider, model: providerResult.model };
    } catch (e: any) {
      const latencyMs = Date.now() - startedAt;
      await this.completeEvent(eventId, 'failed', {
        errorText: (e?.message || 'ai_run_failed').slice(0, 1000),
        latencyMs,
      }).catch(() => undefined);
      throw e;
    }
  }

  async runTriage(input: AiRunInput) {
    return this.runDraft('ai.triage', 'ai.triage.run', 'triage', input);
  }

  async runReferral(input: AiRunInput) {
    return this.runDraft('ai.referral', 'ai.referral.run', 'referral', input);
  }

  async draftNote(input: AiRunInput) {
    return this.runDraft('ai.note_draft', 'ai.note_draft.run', 'note', input);
  }

  async draftCarePlan(input: AiRunInput) {
    return this.runDraft('ai.care_plan_draft', 'ai.care_plan_draft.run', 'care_plan', input);
  }

  async generateEmbeddings(input: AiEmbeddingInput) {
    const actorUserId = this.rc.requireUuidUserId();
    const enabled = await this.featureEnabled('ai.embeddings_generation');
    if (!enabled) throw new ServiceUnavailableException('ai_feature_disabled');

    const target = String(input?.target || '').trim();
    if (!target) throw new BadRequestException('target_required');
    const cfg = await this.vectorTargets.getConfigOrReload(target);
    const tableName = this.validateSqlIdentifier(cfg.table_name, 'target_table');
    const embeddingColumn = this.validateSqlIdentifier(cfg.embedding_column, 'embedding_column');
    const dimension = Math.min(Math.max(Number(cfg.dimension || 1536), 2), 4096);
    const limit = Math.min(Math.max(Number(input.limit || 10) || 10, 1), 50);
    const ids = Array.isArray(input.ids) ? input.ids.map((id) => this.normalizeOptionalUuid(id, 'ids')).filter(Boolean) : [];
    const persist = input.persist ?? !input.dryRun;
    const regenerate = input.regenerate === true;

    const eventId = await this.insertRawEvent({
      actorUserId,
      eventType: 'ai.embeddings.generate',
      featureKey: 'ai.embeddings_generation',
      requestPayload: { target, ids, limit, dryRun: !!input.dryRun, persist, regenerate },
    });
    if (!eventId) throw new ServiceUnavailableException('ai_event_insert_failed');

    const startedAt = Date.now();
    try {
      const candidates = await this.db.runInTx(async (q) => {
        const params: any[] = [];
        const where: string[] = [];
        if (ids.length > 0) {
          params.push(ids);
          where.push(`id = any($${params.length}::uuid[])`);
        }
        if (!regenerate) where.push(`${embeddingColumn} is null`);
        params.push(limit);
        const sql = `select id::text as id, coalesce((${cfg.snippet_expression})::text, '') as text
                       from ${tableName}
                      ${where.length ? `where ${where.join(' and ')}` : ''}
                      order by id
                      limit $${params.length}::int`;
        const { rows } = await q<{ id: string; text: string }>(sql, params);
        return rows.filter((row) => row.text.trim().length > 0);
      });

      const providerResult = candidates.length > 0
        ? await this.callEmbeddingProvider(candidates.map((item) => item.text), dimension, !!input.dryRun)
        : { provider: input.dryRun ? 'dry_run' : this.providerConfig().provider, model: this.embeddingProviderConfig(!!input.dryRun).model, embeddings: [] as number[][] };

      const updatedIds: string[] = [];
      if (persist && providerResult.embeddings.length > 0) {
        await this.db.runInTx(async (q) => {
          for (let i = 0; i < candidates.length; i++) {
            const embedding = this.normalizeEmbedding(providerResult.embeddings[i], dimension);
            const vecLiteral = `[${embedding.join(',')}]`;
            const { rows } = await q<{ id: string }>(
              `update ${tableName} set ${embeddingColumn} = $2::vector where id = $1::uuid returning id::text as id`,
              [candidates[i].id, vecLiteral]
            );
            if (rows[0]?.id) updatedIds.push(rows[0].id);
          }
        });
      }

      const payload = {
        target,
        candidateCount: candidates.length,
        updated: updatedIds.length,
        updatedIds,
        dryRun: !!input.dryRun,
        persisted: persist,
      };
      await this.completeEvent(eventId, 'succeeded', {
        provider: providerResult.provider,
        model: providerResult.model,
        responsePayload: payload,
        latencyMs: Date.now() - startedAt,
      });
      return { ok: true, eventId, ...payload, provider: providerResult.provider, model: providerResult.model };
    } catch (e: any) {
      await this.completeEvent(eventId, 'failed', {
        errorText: (e?.message || 'ai_embedding_generation_failed').slice(0, 1000),
        latencyMs: Date.now() - startedAt,
      }).catch(() => undefined);
      throw e;
    }
  }

  async listDrafts(filters: { petId?: string; encounterId?: string; status?: string; type?: string; limit?: string }) {
    const limit = Math.min(Math.max(parseInt(filters.limit || '50', 10) || 50, 1), 200);
    const petId = this.normalizeOptionalUuid(filters.petId, 'petId');
    const encounterId = this.normalizeOptionalUuid(filters.encounterId, 'encounterId');
    const status = filters.status?.trim() || null;
    const type = filters.type?.trim() || null;
    const { rows } = await this.db.runInTx(async (q) => q<any>(
      `select id, actor_user_id, pet_id, encounter_id, session_id, referral_id, note_id, care_plan_id,
              ai_event_id, prompt_version_id, draft_type, status, payload, review_notes,
              reviewed_by, reviewed_at, created_at, updated_at
         from ai_drafts
        where ($1::uuid is null or pet_id = $1::uuid)
          and ($2::uuid is null or encounter_id = $2::uuid)
          and ($3::text is null or status = $3)
          and ($4::text is null or draft_type = $4)
        order by created_at desc
        limit $5`,
      [petId, encounterId, status, type, limit]
    ));
    return { data: rows };
  }

  async listEvents(filters: { petId?: string; encounterId?: string; status?: string; limit?: string }) {
    const limit = Math.min(Math.max(parseInt(filters.limit || '50', 10) || 50, 1), 200);
    const petId = this.normalizeOptionalUuid(filters.petId, 'petId');
    const encounterId = this.normalizeOptionalUuid(filters.encounterId, 'encounterId');
    const status = filters.status?.trim() || null;
    const { rows } = await this.db.runInTx(async (q) => q<any>(
      `select id, actor_user_id, pet_id, encounter_id, session_id, event_type, feature_key,
              provider, model, prompt_version_id, status, error_text, latency_ms, created_at, updated_at
         from ai_events
        where ($1::uuid is null or pet_id = $1::uuid)
          and ($2::uuid is null or encounter_id = $2::uuid)
          and ($3::text is null or status = $3)
        order by created_at desc
        limit $4`,
      [petId, encounterId, status, limit]
    ));
    return { data: rows };
  }

  async reviewDraft(draftId: string, body: { status?: AiReviewStatus; reviewNotes?: string }) {
    this.validator.validateUUID(draftId, 'draftId');
    const actorId = this.rc.requireUuidUserId();
    const status = body?.status || 'reviewed';
    if (!['reviewed', 'accepted', 'rejected', 'superseded'].includes(status)) {
      throw new BadRequestException('invalid_review_status');
    }
    const { rows: actorRows } = await this.db.runInTx(async (q) => q<{ role: string }>(`select role from users where id = $1::uuid limit 1`, [actorId]));
    const role = actorRows[0]?.role;
    if (role !== 'vet' && role !== 'admin') throw new ForbiddenException('vet_or_admin_required');

    const { rows } = await this.db.runInTx(async (q) => q<any>(
      `update ai_drafts d
          set status = $2,
              review_notes = coalesce($3, review_notes),
              reviewed_by = $4::uuid,
              reviewed_at = now(),
              updated_at = now()
        where d.id = $1::uuid
          and (
            is_admin()
            or exists (select 1 from clinical_encounters ce where ce.id = d.encounter_id and ce.vet_id = auth.uid())
            or exists (select 1 from chat_sessions s where s.id = d.session_id and s.vet_id = auth.uid())
          )
        returning id, actor_user_id, pet_id, encounter_id, session_id, draft_type, status,
                  payload, review_notes, reviewed_by, reviewed_at, created_at, updated_at`,
      [draftId, status, body?.reviewNotes || null, actorId]
    ));
    if (!rows[0]) throw new BadRequestException('draft_not_found_or_not_reviewable');
    return rows[0];
  }
}
