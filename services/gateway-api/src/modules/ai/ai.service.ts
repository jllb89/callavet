import { BadGatewayException, BadRequestException, ForbiddenException, Injectable, ServiceUnavailableException } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { ValidatorService } from '../config/validator.service';
import { VectorTargetService } from '../config/vector-target.service';

type AiDraftType = 'triage' | 'referral' | 'note' | 'care_plan';
type AiReviewStatus = 'reviewed' | 'accepted' | 'rejected' | 'superseded';

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

  private providerConfig(prompt?: PromptVersion, dryRun = false) {
    const provider = dryRun ? 'dry_run' : (process.env.AI_PROVIDER || 'openai');
    const apiKey = process.env.AI_PROVIDER_API_KEY || process.env.OPENAI_API_KEY || '';
    const baseUrl = (process.env.AI_PROVIDER_BASE_URL || 'https://api.openai.com/v1').replace(/\/$/, '');
    const model = prompt?.model || process.env.AI_MODEL || 'gpt-4o-mini';
    const timeoutMs = Math.min(Math.max(Number(process.env.AI_REQUEST_TIMEOUT_MS || '30000') || 30000, 5000), 120000);
    return { provider, apiKey, baseUrl, model, timeoutMs };
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

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), cfg.timeoutMs);
    try {
      const response = await fetch(`${cfg.baseUrl}/chat/completions`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${cfg.apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          model: cfg.model,
          temperature: 0.2,
          response_format: { type: 'json_object' },
          messages: [
            { role: 'system', content: prompt.system_prompt },
            { role: 'user', content: this.renderPrompt(prompt.user_template, context) },
          ],
        }),
        signal: controller.signal,
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new BadGatewayException(data?.error?.message || `ai_provider_http_${response.status}`);
      }
      const content = data?.choices?.[0]?.message?.content;
      if (!content || typeof content !== 'string') throw new BadGatewayException('ai_provider_empty_response');
      try {
        return { provider: cfg.provider, model: cfg.model, payload: JSON.parse(content) };
      } catch {
        throw new BadGatewayException('ai_provider_invalid_json');
      }
    } finally {
      clearTimeout(timer);
    }
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

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), cfg.timeoutMs);
    try {
      const response = await fetch(`${cfg.baseUrl}/embeddings`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${cfg.apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ model: cfg.model, input: texts }),
        signal: controller.signal,
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        throw new BadGatewayException(data?.error?.message || `ai_embedding_provider_http_${response.status}`);
      }
      const embeddings = Array.isArray(data?.data)
        ? data.data.map((item: any) => this.normalizeEmbedding(item?.embedding, dimension))
        : [];
      if (embeddings.length !== texts.length) throw new BadGatewayException('ai_embedding_provider_mismatched_response');
      return { provider: cfg.provider, model: cfg.model, embeddings };
    } finally {
      clearTimeout(timer);
    }
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
