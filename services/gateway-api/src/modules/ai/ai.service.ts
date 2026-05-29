import { BadGatewayException, BadRequestException, ForbiddenException, Injectable, ServiceUnavailableException } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { ValidatorService } from '../config/validator.service';
import { VectorTargetService } from '../config/vector-target.service';

type AiDraftType = 'triage' | 'referral' | 'note' | 'care_plan';
type AiReviewStatus = 'reviewed' | 'accepted' | 'rejected' | 'superseded';
type AiApiMode = 'responses' | 'chat_completions';
type AiReasoningEffort = 'none' | 'low' | 'medium' | 'high' | 'xhigh';

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
};

type AiChatTurnInput = {
  conversationId?: string;
  petId?: string;
  sessionId?: string;
  message?: string;
  messages?: AiChatMessageInput[];
  dryRun?: boolean;
};

type AiChatToolName = 'recommend_specialty' | 'find_vets' | 'check_service_access' | 'get_available_slots';

type AiChatToolCall = {
  type: 'function_call';
  call_id: string;
  name: AiChatToolName | string;
  arguments: string;
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
  ) {}

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
        required: ['message', 'urgency', 'recommendedService', 'actionLabel', 'safetyEscalation'],
        properties: {
          message: { type: 'string' },
          urgency: { type: 'string', enum: ['routine', 'urgent', 'emergency'] },
          recommendedService: { type: ['string', 'null'], enum: ['chat', 'video', 'scheduled_video', null] },
          actionLabel: { type: ['string', 'null'] },
          safetyEscalation: { type: 'boolean' },
        },
      },
    };
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
            petId: { type: ['string', 'null'], description: 'Known pet UUID when available; otherwise null.' },
          },
        },
      },
      {
        type: 'function',
        name: 'find_vets',
        description: 'Find approved vets that cover a selected specialty. Use only after a specialty is known.',
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
              and us.status = 'active'
              and coalesce(us.current_period_end, now()) > now()
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
        recentConversations: conversationRows.rows,
      };
    });
  }

  private chatTurnInstructions(context: AiChatTurnContext) {
    return [
      'You are Call a Vet AI concierge for equine veterinary care.',
      'Reply in Spanish unless the user clearly uses another language.',
      'Your purpose is warm intake, urgency detection, specialty routing, entitlement-aware service recommendation, and concise coordination with professional human vets.',
      'Never diagnose, prescribe medication, recommend medication doses, or imply you replace a veterinarian.',
      'If red flags are present, recommend immediate professional help or local emergency veterinary care.',
      'Use the provided user, horse, subscription, and recent conversation context to personalize naturally. Do not expose raw internal IDs unless needed for tool calls.',
      'If the user has more than one horse and no specific pet is clear, ask which horse this is for before non-emergency service activation.',
      'Before recommending a service, gather the minimum missing context for a useful vet handoff: affected horse, main concern, onset/duration, severity, appetite/water, relevant history/medications, and red flags. Ask at most one concise follow-up at a time.',
      'Do not immediately ask the user to choose a product. Decide whether chat, immediate video, or scheduled video is best based on urgency, symptoms, context, and entitlement signals; then explain the recommendation briefly.',
      'Prepare the conversation so a later veterinarian handoff can include a concise contextualization, not a diagnosis.',
      'Use function tools to choose an existing specialty, find approved vets, check service access, and inspect availability.',
      'Do not invent specialty IDs, vet IDs, appointment slots, entitlements, prices, or session IDs.',
      'Before recommending chat or video activation, call check_service_access for the relevant service type.',
      'Keep final responses short, warm, and action-oriented. If context is insufficient, ask a targeted question instead of showing all service choices.',
      `Server context: ${JSON.stringify(context)}`,
    ].join('\n');
  }

  private normalizeChatMessages(input: AiChatTurnInput) {
    const messages = Array.isArray(input.messages) ? input.messages : [];
    const normalized = messages
      .map((message) => {
        const content = String(message?.content || '').trim();
        if (!content) return null;
        const role = message?.role === 'assistant' || message?.role === 'ai' ? 'assistant' : 'user';
        return { role, content };
      })
      .filter(Boolean) as Array<{ role: 'user' | 'assistant'; content: string }>;
    const currentMessage = String(input.message || '').trim();
    if (currentMessage) normalized.push({ role: 'user', content: currentMessage });
    return normalized.slice(-12);
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
    const requestedPetId = this.normalizeOptionalUuid(String(args.petId || context.petId || ''), 'petId');
    if (requestedPetId && requestedPetId !== context.petId) {
      const { rows } = await this.db.query<{ id: string }>(
        `select id from pets where id = $1::uuid and user_id = $2::uuid limit 1`,
        [requestedPetId, context.actorUserId]
      );
      if (!rows[0]) throw new BadRequestException('pet_not_found_for_user');
    }
    const { rows } = await this.db.query<any>(
      `select distinct on (lower(btrim(name))) id, name, description, coalesce(is_active, true) as is_active
         from vet_specialties
        where nullif(btrim(name), '') is not null
        order by lower(btrim(name)), coalesce(is_active, true) desc, length(coalesce(description, '')) desc, id asc`
    );
    const haystack = symptoms.toLowerCase();
    const boostedTerms = [
      { terms: ['no quiere comer', 'no come', 'dejo de comer', 'dejó de comer', 'apetito', 'colico', 'cólico', 'diarrea', 'gastro'], targets: ['gastro', 'interna', 'internal', 'general', 'urgenc', 'critical', 'crítico'] },
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
      const score = baseScore + boost;
      return { specialty, score };
    }).sort((left, right) => right.score - left.score);
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
      petId: requestedPetId,
    };
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
              coalesce(avg(r.score)::numeric(10,2), 0) as rating_average,
              count(r.id)::int as rating_count,
              (select count(*)::int
                 from chat_sessions s
                where s.vet_id = v.id
                  and s.status = 'active') as active_consults
         from vets v
         join users u on u.id = v.id
         left join ratings r on r.vet_id = v.id
        where v.is_approved = true
          and ($1::uuid is null or array_position(v.specialties, $1::uuid) is not null)
        group by v.id, u.full_name, v.bio, v.years_experience, v.languages
        order by active_consults asc, count(r.id) desc, coalesce(avg(r.score), 0) desc, u.full_name asc
        limit $2`,
      [specialtyId, limit]
    );
    return { ok: true, specialtyId, vets: rows };
  }

  private async checkServiceAccessTool(args: Record<string, any>, context: AiChatTurnContext) {
    const serviceType = String(args.serviceType || '').trim().toLowerCase();
    if (serviceType !== 'chat' && serviceType !== 'video') throw new BadRequestException('serviceType_invalid');
    const { rows } = await this.db.query<any>(
      `select us.id as subscription_id,
              p.code as plan_code,
              coalesce(su.included_chats, p.included_chats, 0)::int as included_chats,
              coalesce(su.included_videos, p.included_videos, 0)::int as included_videos,
              coalesce(su.consumed_chats, 0)::int as consumed_chats,
              coalesce(su.consumed_videos, 0)::int as consumed_videos
         from user_subscriptions us
         join subscription_plans p on p.id = us.plan_id
    left join subscription_usage su
           on su.subscription_id = us.id
          and su.period_start = us.current_period_start
          and su.period_end = us.current_period_end
        where us.user_id = $1::uuid
          and us.status = 'active'
          and coalesce(us.current_period_end, now()) > now()
        order by us.current_period_end desc nulls last
        limit 1`,
      [context.actorUserId]
    );
    const row = rows[0];
    if (!row) {
      return { ok: true, serviceType, canUse: false, reason: 'no_active_subscription' };
    }
    const included = serviceType === 'chat' ? Number(row.included_chats || 0) : Number(row.included_videos || 0);
    const consumed = serviceType === 'chat' ? Number(row.consumed_chats || 0) : Number(row.consumed_videos || 0);
    return {
      ok: true,
      serviceType,
      canUse: consumed < included,
      reason: consumed < included ? 'available' : `no_${serviceType}_entitlement_left`,
      subscriptionId: row.subscription_id,
      planCode: row.plan_code,
      included,
      consumed,
      remaining: Math.max(included - consumed, 0),
    };
  }

  private async getAvailableSlotsTool(args: Record<string, any>) {
    const vetId = this.normalizeOptionalUuid(String(args.vetId || ''), 'vetId');
    if (!vetId) throw new BadRequestException('vetId_required');
    const durationMin = Math.min(Math.max(Number(args.durationMin || 30) || 30, 10), 240);
    const since = args.since ? new Date(String(args.since)) : new Date();
    const until = args.until ? new Date(String(args.until)) : new Date(since.getTime() + 7 * 24 * 60 * 60 * 1000);
    if (Number.isNaN(since.getTime()) || Number.isNaN(until.getTime()) || until <= since) {
      throw new BadRequestException('slot_window_invalid');
    }
    const { rows } = await this.db.query<any>(
      `with params as (
         select $1::uuid as vet_id,
                $2::timestamptz as since,
                $3::timestamptz as until,
                $4::int as dur
       ),
       days as (
         select generate_series(date_trunc('day', (select since from params)), date_trunc('day', (select until from params)), interval '1 day')::date as day
       ),
       avail as (
         select d.day,
                va.start_time as start_t,
                va.end_time as end_t
           from days d
           join vet_availability va on va.weekday = extract(dow from d.day) and va.vet_id = (select vet_id from params)
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
          where vet_id = (select vet_id from params)
            and status = any(array['scheduled','active','confirmed']::text[])
       )
       select slot_start, slot_end
         from slots s
        where s.slot_start >= (select since from params)
          and s.slot_end <= (select until from params)
          and not exists (select 1 from booked b where tstzrange(s.slot_start, s.slot_end) && b.appt_range)
        order by slot_start asc
        limit 5`,
      [vetId, since.toISOString(), until.toISOString(), durationMin]
    );
    return { ok: true, vetId, durationMin, slots: rows.map((row) => ({ start: row.slot_start, end: row.slot_end })) };
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
      default:
        throw new BadGatewayException(`ai_tool_not_allowed:${call.name}`);
    }
  }

  private chatTurnDryRun(context: AiChatTurnContext, message: string) {
    const wantsVideo = /video|videollamada|llamada|urgente|urgent|emergency/i.test(message);
    const petNames = context.pets.map((pet) => pet?.name).filter(Boolean).slice(0, 3);
    const hasMultiplePets = context.pets.length > 1;
    return {
      ok: true,
      dryRun: true,
      provider: 'dry_run',
      model: this.providerConfig(undefined, true).model,
      responseId: null,
      payload: {
        message: wantsVideo
          ? `Puedo ayudarte a preparar esto para un veterinario. ${hasMultiplePets ? `¿Para cuál caballo es: ${petNames.join(', ')}? ` : ''}Por lo que describes, puede convenir una videollamada para valorar urgencia.`
          : `Claro, te ayudo. ${hasMultiplePets ? `¿Para cuál caballo es: ${petNames.join(', ')}? ` : 'Cuéntame desde cuándo pasa y si ha cambiado su apetito, agua o energía. '}Con eso puedo orientar mejor si conviene chat, videollamada inmediata o agendar una videollamada.`,
        urgency: wantsVideo ? 'urgent' : 'routine',
        recommendedService: wantsVideo ? 'video' : 'chat',
        actionLabel: wantsVideo ? 'buscar videollamada' : 'buscar veterinario',
        safetyEscalation: wantsVideo,
      },
      toolResults: [],
      context,
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

  private async callChatTurnProvider(input: AiChatTurnInput, context: AiChatTurnContext) {
    const cfg = this.providerConfig(undefined, !!input.dryRun);
    const messages = this.normalizeChatMessages(input);
    const latestMessage = messages[messages.length - 1]?.content || '';
    if (input.dryRun) return this.chatTurnDryRun(context, latestMessage);
    if (!cfg.apiKey) throw new ServiceUnavailableException('ai_provider_not_configured');
    if (cfg.apiMode !== 'responses') throw new ServiceUnavailableException('ai_chat_turn_requires_responses_api');
    if (!messages.length) throw new BadRequestException('message_required');

    const responseInput: any[] = messages.map((message) => ({ role: message.role, content: message.content }));
    const toolResults: Array<{ name: string; output: any }> = [];
    const tools = this.chatTurnTools();

    for (let step = 0; step < 6; step += 1) {
      const body: Record<string, any> = {
        model: cfg.model,
        store: false,
        instructions: this.chatTurnInstructions(context),
        input: responseInput,
        tools,
        text: { format: this.chatTurnResponseFormat() },
        tool_choice: 'auto',
        parallel_tool_calls: false,
      };
      if (cfg.reasoningEffort) body.reasoning = { effort: cfg.reasoningEffort };
      const data = await this.postProviderJson(cfg, '/responses', body, 'ai_chat_provider_http');
      const output = Array.isArray(data?.output) ? data.output : [];
      const toolCalls = output.filter((item: any): item is AiChatToolCall => item?.type === 'function_call');

      if (!toolCalls.length) {
        const payload = this.parseProviderPayload(this.extractResponsesText(data));
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
        responsePayload: { payload: result.payload, toolResults: result.toolResults, responseId: result.responseId || null },
        latencyMs: Date.now() - startedAt,
      });
      return { ...result, eventId };
    } catch (e: any) {
      await this.completeEvent(eventId, 'failed', {
        errorText: (e?.message || 'ai_chat_turn_failed').slice(0, 1000),
        latencyMs: Date.now() - startedAt,
      }).catch(() => undefined);
      throw e;
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
    eventType: string;
    featureKey: string;
    requestPayload: Record<string, any>;
  }) {
    const { rows } = await this.db.runInTx(async (q) => q<{ id: string }>(
      `insert into ai_events (
         id, actor_user_id, event_type, feature_key, status, request_payload, created_at, updated_at
       ) values (
         gen_random_uuid(), $1::uuid, $2, $3, 'running', coalesce($4::jsonb, '{}'::jsonb), now(), now()
       ) returning id`,
      [args.actorUserId, args.eventType, args.featureKey, JSON.stringify(args.requestPayload)]
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
