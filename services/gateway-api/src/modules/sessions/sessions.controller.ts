import { BadRequestException, Body, Controller, Get, HttpException, HttpStatus, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';
import { EndpointRateLimitGuard } from '../rate-limit/endpoint-rate-limit.guard';
import { RateLimit } from '../rate-limit/rate-limit.decorator';
import { ValidatorService } from '../config/validator.service';
import { NotificationsService } from '../notifications/notifications.service';

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
};

@Controller('sessions')
@UseGuards(AuthGuard)
export class SessionsController {
  constructor(
    private readonly db: DbService,
    private readonly rc: RequestContext,
    private readonly validator: ValidatorService,
    private readonly notifications: NotificationsService,
  ) {}

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
          `select id, user_id, vet_id, pet_id, status, mode, started_at, ended_at
             from chat_sessions
            where user_id = auth.uid() or vet_id = auth.uid()
            order by coalesce(started_at, created_at) desc nulls last
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
          `select id, user_id, vet_id, pet_id, status, mode, started_at, ended_at
             from chat_sessions
            where id = $1
              and (user_id = auth.uid() or vet_id = auth.uid())
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
      if (petId) this.validator.validateUUID(petId, 'petId');
      if (vetId) this.validator.validateUUID(vetId, 'vetId');
      if (specialtyId) this.validator.validateUUID(specialtyId, 'specialtyId');
      if (this.db.isStub) {
        const sessionId = body.sessionId || `sess_${Date.now()}`;
        return { ok: true, mode: 'stub', sessionId, kind, petId, vetId, specialtyId };
      }
      const result = await this.db.runInTx(async (q) => {
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

        if (vetId) {
          const { rows: vetRows } = await q<{ id: string; is_approved: boolean; specialty_ok: boolean }>(
            `select id,
                    is_approved,
                    ($2::uuid is null or array_position(coalesce(specialties, '{}'::uuid[]), $2::uuid) is not null) as specialty_ok
               from vets
              where id = $1::uuid
              limit 1`,
            [vetId, specialtyId]
          );
          const vet = vetRows[0];
          if (!vet) throw new HttpException('vet_not_found', HttpStatus.BAD_REQUEST);
          if (!vet.is_approved) throw new HttpException('vet_not_approved', HttpStatus.BAD_REQUEST);
          if (!vet.specialty_ok) throw new HttpException('vet_missing_specialty', HttpStatus.BAD_REQUEST);
        }

        // 1) Create session first (FK target) using auth.uid() for user_id
        const { rows: r2 } = await q<{ id: string; pet_id: string | null; vet_id: string | null }>(
          `insert into chat_sessions (id, user_id, vet_id, pet_id, status, mode, started_at)
           values (gen_random_uuid(), auth.uid(), $1::uuid, $2::uuid, $3, $4, now())
           returning id, pet_id, vet_id`,
          [vetId, petId, 'active', kind]
        );
        const dbSessionId = r2?.[0]?.id as string;
        const routedPetId = r2?.[0]?.pet_id || null;
        const routedVetId = r2?.[0]?.vet_id || null;
        // 2) Reserve entitlement referencing the created session id
        const reserveFn = kind === 'video' ? 'fn_reserve_video' : 'fn_reserve_chat';
        const { rows: r1 } = await q<{ ok: boolean; subscription_id: string; consumption_id: string; msg: string }>(
          `select * from ${reserveFn}(auth.uid(), trim($1)::uuid)`,
          [dbSessionId]
        );
        const reserve = r1?.[0];
        const ok = reserve?.ok === true;
        const consumptionId = reserve?.consumption_id || undefined;
        const msg = reserve?.msg;
        let overage = !ok || !consumptionId;
        let creditConsumptionId: string | null = null;
        let creditUsedCode: string | null = null;
        let creditRemaining: number | null = null;
        // Ensure we have a subscription id before trying credits
        let subIdForCredit: string | undefined = reserve?.subscription_id;
        if (overage && !subIdForCredit) {
          const { rows: subs } = await q<{ id: string }>(
            `select id
               from user_subscriptions
              where user_id = auth.uid()
                and status = 'active'
                and coalesce(current_period_end, now()) > now()
              order by current_period_end desc nulls last
              limit 1`
          );
          subIdForCredit = subs[0]?.id;
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
        return { dbSessionId, petId: routedPetId, vetId: routedVetId, specialtyId, consumptionId, overage, msg, creditConsumptionId, creditUsedCode, creditRemaining, checkout };
      });
      if (result.overage) {
        return {
          ok: true,
          sessionId: result.dbSessionId,
          petId: result.petId,
          vetId: result.vetId,
          specialtyId: result.specialtyId,
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
      const finalConsumption = result.consumptionId || result.creditConsumptionId || undefined;
      return {
        ok: true,
        sessionId: result.dbSessionId,
        petId: result.petId,
        vetId: result.vetId,
        specialtyId: result.specialtyId,
        consumptionId: finalConsumption,
        kind,
        overage: false,
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
        return rows.length;
      });
      if (!updated) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
      return { ok: true, sessionId: body.sessionId, ended: true };
    } catch (e: any) {
      throw new HttpException(e?.message || 'end_failed', HttpStatus.BAD_REQUEST);
    }
  }
}
