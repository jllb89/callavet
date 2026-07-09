import { BadRequestException, Body, Controller, Get, HttpException, HttpStatus, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';
import { EndpointRateLimitGuard } from '../rate-limit/endpoint-rate-limit.guard';
import { RateLimit } from '../rate-limit/rate-limit.decorator';
import { ValidatorService } from '../config/validator.service';
import { NotificationsService } from '../notifications/notifications.service';
import { EntitlementService } from '../subscriptions/entitlement.service';
import { AiService } from '../ai/ai.service';

type AiSessionStartContext = {
  source?: string;
  aiEventId?: string;
  assistantPayload?: Record<string, any>;
  messages?: Array<Record<string, any>>;
  routing?: Record<string, any>;
};

type SessionStartBody = {
  userId?: string;
  kind?: 'chat'|'video';
  mode?: 'chat'|'video';
  type?: 'chat'|'video';
  sessionId?: string;
  petId?: string;
  pet_id?: string;
  vetId?: string;
  vet_id?: string;
  specialtyId?: string;
  specialty_id?: string;
  priority?: string;
  urgency?: string;
  aiContext?: AiSessionStartContext;
};

const SESSION_PRIORITIES = new Set(['routine', 'urgent', 'emergency']);
const VET_LOCK_TTL_BY_KIND: Record<'chat'|'video', string> = {
  chat: '45 minutes',
  video: '90 minutes',
};

@Controller('sessions')
@UseGuards(AuthGuard)
export class SessionsController {
  constructor(
    private readonly db: DbService,
    private readonly rc: RequestContext,
    private readonly validator: ValidatorService,
    private readonly notifications: NotificationsService,
    private readonly entitlements: EntitlementService,
    private readonly ai: AiService,
  ) {}

  private roadmapLog(event: string, metadata: Record<string, any> = {}) {
    console.log(JSON.stringify({
      scope: 'video_handoff_roadmap',
      component: 'sessions',
      event,
      at: new Date().toISOString(),
      ...metadata,
    }));
  }

  private normalizeAiContext(value: AiSessionStartContext | undefined) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
    const source = String(value.source || '').trim();
    const hasPayload = value.assistantPayload && typeof value.assistantPayload === 'object' && !Array.isArray(value.assistantPayload);
    const hasMessages = Array.isArray(value.messages) && value.messages.length > 0;
    const aiEventId = String(value.aiEventId || '').trim();
    if (!source && !hasPayload && !hasMessages && !aiEventId) return null;
    return value;
  }

  private async generateAiHandoff(sessionId: string, aiContext: AiSessionStartContext | null) {
    if (!aiContext) return null;
    this.roadmapLog('handoff.generate.requested', {
      sessionId,
      source: aiContext.source || null,
      sourceAiEventId: aiContext.aiEventId || null,
      messageCount: Array.isArray(aiContext.messages) ? aiContext.messages.length : 0,
      hasAssistantPayload: !!aiContext.assistantPayload,
    });
    try {
      const result = await this.ai.generateSessionHandoff({
        sessionId,
        sourceAiEventId: aiContext.aiEventId,
        aiContext,
      });
      this.roadmapLog('handoff.generate.succeeded', {
        sessionId,
        eventId: result?.eventId || null,
        handoffId: result?.handoff?.id || null,
        provider: result?.provider || null,
        model: result?.model || null,
      });
      return result;
    } catch (error: any) {
      this.roadmapLog('handoff.generate.failed', {
        sessionId,
        error: error?.message || String(error),
      });
      console.error('[sessions.start] ai handoff generation failed:', error?.message || error);
      return null;
    }
  }

  @Get()
  async list(
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string,
  ) {
    try {
      const limit = Math.min(Math.max(parseInt(limitStr || '20', 10) || 20, 1), 100);
      const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
      if (this.db.isStub) {
        return { data: [], mode: 'stub' } as any;
      }
      const rows = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `select s.id,
                  s.user_id,
                  s.vet_id,
                  s.pet_id,
                  s.specialty_id,
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
            where user_id = auth.uid() or vet_id = auth.uid()
            order by coalesce(s.started_at, s.created_at) desc nulls last
            limit $1 offset $2`,
          [limit, offset]
        );
        return rows as any[];
      });
      return { data: rows };
    } catch (e: any) {
      throw new HttpException(e?.message || 'list_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get(':sessionId')
  async detail(@Param('sessionId') sessionId: string) {
    try {
      if (this.db.isStub) return { id: sessionId, status: 'active' } as any;
      const row = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `select s.id,
                  s.user_id,
                  s.vet_id,
                  s.pet_id,
                  s.specialty_id,
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
            where s.id = $1
              and (s.user_id = auth.uid() or s.vet_id = auth.uid())
            limit 1`,
          [sessionId]
        );
        return rows[0];
      });
      if (!row) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
      return row;
    } catch (e: any) {
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'detail_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get(':sessionId/handoff')
  async handoff(@Param('sessionId') sessionId: string) {
    try {
      this.validator.validateUUID(sessionId, 'sessionId');
      if (this.db.isStub) return { ready: false, sessionId, handoff: null, mode: 'stub' } as any;
      const row = await this.db.runInTx(async (q) => {
        const { rows } = await q<any>(
          `select s.id::text as session_id,
                  s.user_id::text as user_id,
                  s.vet_id::text as vet_id,
                  s.pet_id::text as pet_id,
                  s.specialty_id::text as specialty_id,
                  s.priority,
                  s.status,
                  s.mode,
                  s.started_at,
                  p.name as pet_name,
                  vu.full_name as vet_name,
                  vs.name as specialty_name,
                  h.id::text as handoff_id,
                  h.ai_event_id::text as ai_event_id,
                  h.source_ai_event_id::text as source_ai_event_id,
                  h.urgency as handoff_urgency,
                  h.summary_text,
                  h.reported_signs,
                  h.red_flags,
                  h.questions_answered,
                  h.questions_unanswered,
                  h.recommended_first_checks,
                  h.created_at as handoff_created_at
             from chat_sessions s
        left join pets p on p.id = s.pet_id
        left join users vu on vu.id = s.vet_id
        left join vet_specialties vs on vs.id = s.specialty_id
        left join lateral (
                  select *
                    from ai_handoffs h
                   where h.session_id = s.id
                   order by h.created_at desc
                   limit 1
             ) h on true
            where s.id = $1::uuid
              and (s.user_id = auth.uid() or s.vet_id = auth.uid() or is_admin())
            limit 1`,
          [sessionId]
        );
        return rows[0];
      });
      if (!row) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
      return {
        ready: !!row.handoff_id,
        session: {
          id: row.session_id,
          userId: row.user_id,
          vetId: row.vet_id,
          petId: row.pet_id,
          specialtyId: row.specialty_id,
          priority: row.priority,
          status: row.status,
          mode: row.mode,
          startedAt: row.started_at,
          petName: row.pet_name,
          vetName: row.vet_name,
          specialtyName: row.specialty_name,
        },
        handoff: row.handoff_id ? {
          id: row.handoff_id,
          aiEventId: row.ai_event_id,
          sourceAiEventId: row.source_ai_event_id,
          urgency: row.handoff_urgency,
          summaryText: row.summary_text,
          reportedSigns: row.reported_signs || [],
          redFlags: row.red_flags || [],
          questionsAnswered: row.questions_answered || [],
          questionsUnanswered: row.questions_unanswered || [],
          recommendedFirstChecks: row.recommended_first_checks || [],
          createdAt: row.handoff_created_at,
        } : null,
      };
    } catch (e: any) {
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'handoff_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Patch(':sessionId')
  async patch(@Param('sessionId') sessionId: string, @Body() body: { status?: string }) {
    try {
      if (!body || !body.status) throw new HttpException('status_required', HttpStatus.BAD_REQUEST);
      if (this.db.isStub) return { id: sessionId, status: body.status } as any;
      const status = String(body.status).toLowerCase();
      const endNow = status === 'completed' || status === 'canceled';
      
      // Track old status before update
      let oldStatus: string | null = null;
      
      const row = await this.db.runInTx(async (q) => {
        // Fetch old state first
        const { rows: oldRows } = await q(
          `select id, user_id, vet_id, pet_id, status, mode, started_at, ended_at
             from chat_sessions
            where id = $1
              and (user_id = auth.uid() or vet_id = auth.uid())
            limit 1`,
          [sessionId]
        );
        oldStatus = oldRows[0]?.status || null;
        
        const { rows } = await q(
          `update chat_sessions
              set status = $2,
                  ended_at = case when $3 then now() else ended_at end,
                  updated_at = now()
            where id = $1
              and (user_id = auth.uid() or vet_id = auth.uid())
            returning id, user_id, vet_id, pet_id, status, mode, started_at, ended_at`,
          [sessionId, status, endNow]
        );
        if (rows.length && endNow) {
          await q('select fn_release_vet_consult_lock($1::uuid, $2)', [sessionId, `session_${status}`]);
        }
        return rows[0];
      });
      if (!row) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
      
      // Fire-and-forget notifications for status transitions
      try {
        if (status === 'active' && oldStatus !== 'active') {
          // Consult starting
          this.notifications.sendEvent({
            eventType: 'consult.start',
            userId: row?.user_id,
            channel: 'email',
            variables: {
              sessionId: row?.id,
              mode: row?.mode,
            },
          }).catch(e => console.error('[session.patch:active] notification failed:', e));
        } else if (['completed', 'canceled'].includes(status) && !['completed', 'canceled'].includes(oldStatus || '')) {
          // Consult ending
          this.notifications.sendEvent({
            eventType: 'consult.end',
            userId: row?.user_id,
            channel: 'email',
            variables: {
              sessionId: row?.id,
              reason: status,
            },
          }).catch(e => console.error('[session.patch:end] notification failed:', e));
        }
      } catch (e) {
        // Swallow notification errors; do not block status update
      }
      
      return row;
    } catch (e: any) {
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'patch_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('start')
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'sessions.start', limit: 6, windowMs: 60_000 })
  async start(@Body() body: SessionStartBody) {
    try {
      // Support `kind`, `mode`, or `type` field from clients; default chat
      const incoming = (body.kind || body.mode || body.type || 'chat')?.toString().toLowerCase();
      const kind: 'chat'|'video' = incoming === 'video' ? 'video' : 'chat';
      if (body.sessionId) this.validator.validateUUID(body.sessionId, 'sessionId');
      const petId = (body.petId || body.pet_id || '').toString().trim() || null;
      const vetId = (body.vetId || body.vet_id || '').toString().trim() || null;
      const specialtyId = (body.specialtyId || body.specialty_id || '').toString().trim() || null;
      const priority = (body.priority || body.urgency || '').toString().trim().toLowerCase() || null;
      const aiContext = this.normalizeAiContext(body.aiContext);
      this.roadmapLog('session.start.received', {
        kind,
        petId,
        vetId,
        specialtyId,
        priority,
        hasAiContext: !!aiContext,
        sourceAiEventId: aiContext?.aiEventId || null,
      });
      if (petId) this.validator.validateUUID(petId, 'petId');
      if (vetId) this.validator.validateUUID(vetId, 'vetId');
      if (specialtyId) this.validator.validateUUID(specialtyId, 'specialtyId');
      if (priority && !SESSION_PRIORITIES.has(priority)) throw new HttpException('invalid_priority', HttpStatus.BAD_REQUEST);
      if (this.db.isStub) {
        const sessionId = body.sessionId || `sess_${Date.now()}`;
        return { ok: true, mode: 'stub', sessionId, kind, petId, vetId, specialtyId, priority };
      }
      const result = await this.db.runInTx(async (q) => {
        await q(`select fn_release_expired_vet_consult_locks()`);
        if (petId) {
          const { rows: petRows } = await q<{ id: string }>(
            `select id
               from pets
              where id = $1::uuid
                and user_id = auth.uid()
              limit 1`,
            [petId]
          );
          if (!petRows[0]) throw new HttpException('pet_not_found_for_user', HttpStatus.BAD_REQUEST);
        }

        if (specialtyId) {
          const { rows: specialtyRows } = await q<{ id: string }>(
            `select id from vet_specialties where id = $1::uuid and coalesce(is_active, true) limit 1`,
            [specialtyId]
          );
          if (!specialtyRows[0]) throw new HttpException('specialty_not_found', HttpStatus.BAD_REQUEST);
        }

        let assignedVetId = vetId;
        if (!assignedVetId && kind === 'chat') {
          const { rows: candidateRows } = await q<{ id: string; specialty_match: boolean }>(
            `select v.id
                    ,($1::uuid is not null and array_position(coalesce(v.specialties, '{}'::uuid[]), $1::uuid) is not null) as specialty_match
               from vets v
          left join ratings r
                 on r.vet_id = v.id
          left join vet_consult_locks l
                 on l.vet_id = v.id
                and l.released_at is null
                and l.expires_at > now()
                and exists (
                  select 1
                    from chat_sessions locked_session
                   where locked_session.id = l.session_id
                     and locked_session.status = 'active'
                )
              where v.is_approved = true
                and l.vet_id is null
              group by v.id, v.created_at, v.specialties
              order by specialty_match desc, coalesce(avg(r.score), 0) desc, count(r.id) desc, v.created_at asc
              limit 1`,
            [specialtyId]
          );
          assignedVetId = candidateRows[0]?.id || null;
          this.roadmapLog('vet_assignment.resolved', {
            requestedVetId: vetId,
            assignedVetId,
            specialtyId,
            kind,
            specialtyMatch: candidateRows[0]?.specialty_match ?? null,
          });
        }
        if (kind === 'chat' && !assignedVetId) {
          throw new HttpException('no_available_vet', HttpStatus.CONFLICT);
        }

        if (assignedVetId) {
          const { rows: vetRows } = await q<{ id: string; is_approved: boolean; specialty_ok: boolean }>(
            `select id,
                    is_approved,
                    true as specialty_ok
               from vets
              where id = $1::uuid
              limit 1`,
            [assignedVetId]
          );
          const vet = vetRows[0];
          if (!vet) throw new HttpException('vet_not_found', HttpStatus.BAD_REQUEST);
          if (!vet.is_approved) throw new HttpException('vet_not_approved', HttpStatus.BAD_REQUEST);
          if (!vet.specialty_ok) throw new HttpException('vet_missing_specialty', HttpStatus.BAD_REQUEST);
          this.roadmapLog('vet_lock.check', { vetId: assignedVetId, specialtyId, kind });
          const { rows: lockRows } = await q<{ session_id: string; expires_at: string }>(
            `select session_id, expires_at::text
               from vet_consult_locks
              where vet_id = $1::uuid
                and released_at is null
                and expires_at > now()
              limit 1
              for update`,
            [assignedVetId]
          );
          if (lockRows[0]) {
            this.roadmapLog('vet_lock.busy', {
              vetId: assignedVetId,
              blockingSessionId: lockRows[0].session_id,
              expiresAt: lockRows[0].expires_at,
            });
            throw new HttpException('vet_busy', HttpStatus.CONFLICT);
          }
        }

        // 1) Create session first (FK target) using auth.uid() for user_id
        const { rows: r2 } = await q<{ id: string; pet_id: string | null; vet_id: string | null; specialty_id: string | null; priority: string | null }>(
          `insert into chat_sessions (id, user_id, vet_id, pet_id, specialty_id, priority, status, mode, started_at)
           values (gen_random_uuid(), auth.uid(), $1::uuid, $2::uuid, $3::uuid, $4, $5, $6, now())
           returning id, pet_id, vet_id, specialty_id, priority`,
          [assignedVetId, petId, specialtyId, priority, 'active', kind]
        );
        const dbSessionId = r2?.[0]?.id as string;
        const routedPetId = r2?.[0]?.pet_id || null;
        const routedVetId = r2?.[0]?.vet_id || null;
        const routedSpecialtyId = r2?.[0]?.specialty_id || null;
        const routedPriority = r2?.[0]?.priority || null;
        if (routedVetId) {
          const lockResult = await q<{ vet_id: string }>(
            `insert into vet_consult_locks (vet_id, session_id, mode, expires_at, reason, created_at, updated_at)
             values ($1::uuid, $2::uuid, $3, now() + $4::interval, 'session_start', now(), now())
             on conflict (vet_id) do update
               set session_id = case
                     when vet_consult_locks.released_at is not null or vet_consult_locks.expires_at <= now() then excluded.session_id
                     else vet_consult_locks.session_id
                   end,
                   mode = case
                     when vet_consult_locks.released_at is not null or vet_consult_locks.expires_at <= now() then excluded.mode
                     else vet_consult_locks.mode
                   end,
                   locked_at = case
                     when vet_consult_locks.released_at is not null or vet_consult_locks.expires_at <= now() then now()
                     else vet_consult_locks.locked_at
                   end,
                   expires_at = case
                     when vet_consult_locks.released_at is not null or vet_consult_locks.expires_at <= now() then excluded.expires_at
                     else vet_consult_locks.expires_at
                   end,
                   released_at = case
                     when vet_consult_locks.released_at is not null or vet_consult_locks.expires_at <= now() then null
                     else vet_consult_locks.released_at
                   end,
                   reason = case
                     when vet_consult_locks.released_at is not null or vet_consult_locks.expires_at <= now() then excluded.reason
                     else vet_consult_locks.reason
                   end,
                   updated_at = now()
             where vet_consult_locks.released_at is not null or vet_consult_locks.expires_at <= now()
             returning vet_id`,
            [routedVetId, dbSessionId, kind, VET_LOCK_TTL_BY_KIND[kind]]
          );
          if (!lockResult.rows[0]) {
            this.roadmapLog('vet_lock.conflict_on_acquire', { vetId: routedVetId, sessionId: dbSessionId, kind });
            throw new HttpException('vet_busy', HttpStatus.CONFLICT);
          }
          this.roadmapLog('vet_lock.acquired', {
            vetId: routedVetId,
            sessionId: dbSessionId,
            kind,
            ttl: VET_LOCK_TTL_BY_KIND[kind],
          });
        }
        // 2) Reserve entitlement referencing the created session id
        const reserve = await this.entitlements.reserveForAuthUser(q, kind, dbSessionId);
        const ok = reserve?.ok === true;
        const consumptionId = reserve?.consumption_id || undefined;
        const msg = reserve?.msg;
        let overage = !ok || !consumptionId;
        let creditConsumptionId: string | null = null;
        let creditUsedCode: string | null = null;
        let creditRemaining: number | null = null;
        // Ensure we have a subscription id before trying credits
        let subIdForCredit: string | undefined = reserve?.subscription_id || undefined;
        if (overage && !subIdForCredit) {
          subIdForCredit = await this.entitlements.activeSubscriptionIdForAuthUser(q) || undefined;
        }
        // Try auto credit draw when out of entitlement
        if (overage && subIdForCredit) {
          const { rows: creditRows } = await q<{ id: string; code: string }>(
            `select oc.id, oi.code
               from overage_credits oc
               join overage_items oi on oi.id = oc.overage_item_id
              where oc.user_id = auth.uid()
                and oc.remaining_units > 0
                and (oi.metadata->>'type') = $1
              order by oc.expires_at nulls last
              limit 1
              for update`,
            [kind]
          );
          if (creditRows[0]) {
            const creditId = creditRows[0].id;
            creditUsedCode = creditRows[0].code;
            const { rows: upd } = await q<{ remaining_units: number }>(
              `update overage_credits
                  set remaining_units = remaining_units - 1,
                      updated_at = now()
                where id = $1
                  and remaining_units > 0
                returning remaining_units`,
              [creditId]
            );
            if (upd[0]) {
              creditRemaining = upd[0].remaining_units;
              const { rows: cons } = await q<{ id: string }>(
                `insert into entitlement_consumptions (id, subscription_id, session_id, consumption_type, amount, source, created_at)
                 values (gen_random_uuid(), $1::uuid, $2::uuid, $3::text, 1, 'credit', now())
                 returning id`,
                [subIdForCredit, dbSessionId, kind]
              );
              creditConsumptionId = cons[0]?.id || null;
              if (creditConsumptionId) {
                overage = false;
              }
            }
          }
        }
        // If still overage, mark session pending payment and create a one-off checkout
        let checkout: { session_id: string; url: string } | null = null;
        if (overage) {
          await q('update chat_sessions set status = $2, updated_at = now() where id = $1', [dbSessionId, 'pending_payment']);
          await q(
            `update vet_consult_locks
                set released_at = now(), updated_at = now(), reason = 'pending_payment'
              where session_id = $1::uuid
                and released_at is null`,
            [dbSessionId]
          );
          const sk = process.env.STRIPE_SECRET_KEY || '';
          const successUrl = process.env.CHECKOUT_SUCCESS_URL || 'http://localhost:3000/overage/success';
          const cancelUrl = process.env.CHECKOUT_CANCEL_URL || 'http://localhost:3000/overage/cancel';
          if (sk) {
            // Resolve overage item by kind
            const { rows: itemRow } = await q<any>(
              `select id, name, amount_cents, currency from overage_items where is_active and (metadata->>'type') = $1 limit 1`,
              [kind]
            );
            if (itemRow[0]) {
              const Stripe = require('stripe');
              const stripe = new Stripe(sk, { apiVersion: '2024-06-20' });
              const session = await stripe.checkout.sessions.create({
                mode: 'payment',
                line_items: [{
                  price_data: {
                    currency: (itemRow[0].currency || 'mxn').toLowerCase(),
                    product_data: { name: itemRow[0].name },
                    unit_amount: itemRow[0].amount_cents,
                  },
                  quantity: 1,
                }],
                success_url: successUrl + '?session_id={CHECKOUT_SESSION_ID}',
                cancel_url: cancelUrl,
                metadata: { user_id: (this.rc.claims && (this.rc.claims as any).sub) || '', overage_item_code: (kind === 'video' ? 'video_unit' : 'chat_unit'), original_session_id: dbSessionId },
              });
              // Persist purchase
              await q(
                `insert into overage_purchases (user_id, overage_item_id, status, stripe_checkout_session_id, quantity, amount_cents_total, currency, original_session_id)
                 values (auth.uid(), $1::uuid, 'checkout_created', $2, 1, $3, $4, $5::uuid)
                 on conflict (stripe_checkout_session_id) do nothing`,
                [itemRow[0].id, session.id, itemRow[0].amount_cents, (itemRow[0].currency || 'mxn').toLowerCase(), dbSessionId]
              );
              checkout = { session_id: session.id, url: session.url };
            }
          }
        }
        const finalConsumptionId = consumptionId || creditConsumptionId;
        let chatCommitted = false;
        if (!overage && kind === 'chat' && finalConsumptionId) {
          const { rows: committedRows } = await q<{ ok: boolean }>(
            `select fn_commit_consumption($1::uuid) as ok`,
            [finalConsumptionId]
          );
          chatCommitted = committedRows[0]?.ok === true;
        }
        return { dbSessionId, petId: routedPetId, vetId: routedVetId, specialtyId: routedSpecialtyId, priority: routedPriority, consumptionId, overage, msg, creditConsumptionId, creditUsedCode, creditRemaining, checkout, chatCommitted };
      });
      if (result.overage) {
        this.roadmapLog('session.start.pending_payment', {
          sessionId: result.dbSessionId,
          kind,
          vetId: result.vetId,
          reason: result.msg || 'no_entitlement',
        });
        return {
          ok: true,
          sessionId: result.dbSessionId,
          petId: result.petId,
          vetId: result.vetId,
          specialtyId: result.specialtyId,
          priority: result.priority,
          kind,
          overage: true,
          overageReason: result.msg || 'no_entitlement',
          consumptionId: result.consumptionId || null,
          payment: result.checkout ? {
            checkout_session_id: result.checkout.session_id,
            url: result.checkout.url,
            status: 'pending',
            type: 'one_off'
          } : {
            stub: true,
            status: 'pending',
            type: 'one_off',
            currency: 'usd',
            amount: null,
            reason: result.msg || 'no_entitlement'
          },
        };
      }
      const handoff = await this.generateAiHandoff(result.dbSessionId, aiContext);
      const finalConsumption = result.consumptionId || result.creditConsumptionId || undefined;
      this.roadmapLog('session.start.completed', {
        sessionId: result.dbSessionId,
        kind,
        petId: result.petId,
        vetId: result.vetId,
        specialtyId: result.specialtyId,
        priority: result.priority,
        hasHandoff: !!handoff?.handoff,
        handoffId: handoff?.handoff?.id || null,
        consumptionId: finalConsumption || null,
        consumptionCommitted: kind === 'chat' ? result.chatCommitted === true : false,
      });
      return {
        ok: true,
        sessionId: result.dbSessionId,
        petId: result.petId,
        vetId: result.vetId,
        specialtyId: result.specialtyId,
        priority: result.priority,
        consumptionId: finalConsumption,
        consumptionCommitted: kind === 'chat' ? result.chatCommitted === true : false,
        kind,
        overage: false,
        handoff: handoff ? { id: handoff.handoff?.id || null, ready: !!handoff.handoff } : undefined,
        credit: result.creditConsumptionId ? { used: true, code: result.creditUsedCode, remaining: result.creditRemaining } : undefined,
      };
    } catch (e: any) {
      throw new HttpException(e?.message || 'start_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('end')
  async end(@Body() body: { sessionId: string; consumptionId?: string }) {
    try {
      if (this.db.isStub) return { ok: true, mode: 'stub', sessionId: body.sessionId, ended: true };
      const updated = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          'update chat_sessions set ended_at = now(), status = $2 where id = $1 and (user_id = auth.uid() or vet_id = auth.uid()) returning id',
          [body.sessionId, 'completed']
        );
        if (rows.length && body.consumptionId) {
          await q('select fn_commit_consumption($1) as ok', [body.consumptionId]);
        }
        if (rows.length) {
          await q('select fn_release_vet_consult_lock($1::uuid, $2)', [body.sessionId, 'session_end']);
        }
        return rows.length;
      });
      if (!updated) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
      return { ok: true, sessionId: body.sessionId, ended: true };
    } catch (e: any) {
      throw new HttpException(e?.message || 'end_failed', HttpStatus.BAD_REQUEST);
    }
  }
}
