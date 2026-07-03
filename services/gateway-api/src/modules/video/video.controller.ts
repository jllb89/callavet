import { BadRequestException, Body, Controller, ForbiddenException, Get, Headers, HttpException, HttpStatus, NotFoundException, Param, Post, Req, UnauthorizedException, UseGuards } from '@nestjs/common';
import type { Request } from 'express';
import { AuthGuard } from '../auth/auth.guard';
import { EndpointRateLimitGuard } from '../rate-limit/endpoint-rate-limit.guard';
import { RateLimit } from '../rate-limit/rate-limit.decorator';
import { ValidatorService } from '../config/validator.service';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { EntitlementService } from '../subscriptions/entitlement.service';
import { AiService } from '../ai/ai.service';
import { LiveKitParticipantRole, LiveKitService } from './livekit.service';

type TxQuery = <R = any>(sql: string, args?: any[]) => Promise<{ rows: R[] }>;
type VideoEndActorRole = LiveKitParticipantRole | 'system';
type VideoEndReason = 'owner_ended' | 'vet_ended' | 'admin_ended' | 'network_disconnect' | 'timeout_no_show' | 'provider_room_finished' | 'room_end' | 'reconcile_timeout';
type VideoEndContext = {
  actorRole: VideoEndActorRole;
  actorUserId?: string | null;
  reason: VideoEndReason;
};

@Controller('video')
export class VideoController {
  constructor(
    private readonly validator: ValidatorService,
    private readonly db: DbService,
    private readonly rc: RequestContext,
    private readonly livekit: LiveKitService,
    private readonly entitlements: EntitlementService,
    private readonly ai: AiService,
  ) {}

  private roadmapLog(event: string, metadata: Record<string, any> = {}) {
    console.log(JSON.stringify({
      scope: 'video_handoff_roadmap',
      component: 'video',
      event,
      at: new Date().toISOString(),
      ...metadata,
    }));
  }

  private async getAuthorizedVideoSession(sessionId: string) {
    if (this.db.isStub) {
      return {
        id: sessionId,
        user_id: this.rc.userId || null,
        vet_id: null,
        status: 'active',
        mode: 'video',
        consumption_id: null,
        consumption_finalized: null,
      } as any;
    }

    const row = await this.db.runInTx(async (q) => {
      const { rows } = await q<{
        id: string;
        user_id: string | null;
        vet_id: string | null;
        status: string | null;
        mode: string | null;
        consumption_id: string | null;
        consumption_finalized: boolean | null;
      }>(
        `select s.id,
                s.user_id,
                s.vet_id,
                s.status,
                s.mode,
                ec.id as consumption_id,
                ec.finalized as consumption_finalized
           from chat_sessions s
      left join lateral (
            select id, finalized
              from entitlement_consumptions
             where session_id = s.id
               and consumption_type = 'video'
               and canceled_at is null
             order by created_at desc
             limit 1
           ) ec on true
          where s.id = $1::uuid
            and (s.user_id = auth.uid() or s.vet_id = auth.uid())
          limit 1`,
        [sessionId]
      );
      return rows[0];
    });

    if (!row) throw new NotFoundException('session_not_found');
    if (row.mode !== 'video') throw new BadRequestException('session_is_not_video');
    return row;
  }

  private assertVideoSessionCanJoin(session: { status: string | null }) {
    const status = String(session.status || '').toLowerCase();
    if (['completed', 'canceled', 'no_show'].includes(status)) {
      throw new BadRequestException('video_session_closed');
    }
    if (status === 'pending_payment') {
      throw new HttpException({ ok: false, reason: 'video_entitlement_payment_required' }, HttpStatus.PAYMENT_REQUIRED);
    }
  }

  private async ensureVideoEntitlementReservation(
    session: { id: string; user_id: string | null; consumption_id?: string | null },
    role: LiveKitParticipantRole,
  ) {
    if (session.consumption_id) return session.consumption_id;
    if (!session.user_id) throw new BadRequestException('session_owner_missing');
    if (role !== 'owner' && role !== 'admin') {
      const canReserveForRejoin = await this.canReserveVideoRejoinForVet(session.id);
      if (!canReserveForRejoin) {
        throw new HttpException({ ok: false, reason: 'video_entitlement_not_reserved' }, HttpStatus.PAYMENT_REQUIRED);
      }
      this.roadmapLog('room.rejoin_reserve_for_vet', { sessionId: session.id, role });
    }
    const result = await this.db.runInTx(async (q) => this.entitlements.reserveForUser(q, 'video', session.user_id!, session.id));
    if (result?.ok && result.consumption_id) return result.consumption_id;
    throw new HttpException({ ok: false, reason: result?.msg || 'video_entitlement_required' }, HttpStatus.PAYMENT_REQUIRED);
  }

  private async canReserveVideoRejoinForVet(sessionId: string) {
    if (this.db.isStub) return true;
    const { rows } = await this.db.runInTx(async (q) => q<{ ok: boolean }>(
      `select exists (
         select 1
           from video_session_lifecycle v
           join chat_sessions s on s.id = v.session_id
          where v.session_id = $1::uuid
            and s.status = 'active'
            and v.rejoin_eligible_until is not null
            and v.rejoin_eligible_until > now()
            and coalesce(v.end_reason, v.safety_reason) in ('owner_ended', 'vet_ended', 'admin_ended')
       ) as ok`,
      [sessionId]
    ));
    return rows[0]?.ok === true;
  }

  private async markRoomProvisioned(sessionId: string, roomName: string, consumptionId?: string | null) {
    if (this.db.isStub) return;
    await this.db.runInTx(async (q) => {
      await q(
        `insert into video_session_lifecycle (session_id, room_name, status, entitlement_consumption_id, created_at, updated_at)
         values ($1::uuid, $2, 'pending', $3::uuid, now(), now())
         on conflict (session_id) do update
           set room_name = excluded.room_name,
               entitlement_consumption_id = coalesce(video_session_lifecycle.entitlement_consumption_id, excluded.entitlement_consumption_id),
               updated_at = now()`,
        [sessionId, roomName, consumptionId || null]
      );
    });
    this.roadmapLog('room.provisioned', { sessionId, roomName, hasConsumption: !!consumptionId });
  }

  private async markVideoRoomEnded(sessionId: string, roomName: string, endContext: VideoEndContext) {
    if (this.db.isStub) return { action: 'stub', reason: 'stub' };
    return this.db.runInTx(async (q) => {
      const rejoinEligible = ['owner_ended', 'vet_ended', 'admin_ended'].includes(endContext.reason);
      await q(
        `insert into video_session_lifecycle (
           session_id, room_name, status, room_finished_at, safety_reason,
           end_reason, end_actor_role, end_actor_user_id, rejoin_eligible_until,
           created_at, updated_at
         )
         values (
           $1::uuid, $2, 'ended', now(), $3,
           $3, $4, $5::uuid, case when $6 then now() + interval '10 minutes' else null end,
           now(), now()
         )
         on conflict (session_id) do update
           set room_name = coalesce(excluded.room_name, video_session_lifecycle.room_name),
               room_finished_at = coalesce(video_session_lifecycle.room_finished_at, now()),
               safety_reason = $3,
               end_reason = $3,
               end_actor_role = $4,
               end_actor_user_id = $5::uuid,
               rejoin_eligible_until = case when $6 then coalesce(video_session_lifecycle.rejoin_eligible_until, now() + interval '10 minutes') else video_session_lifecycle.rejoin_eligible_until end,
               updated_at = now()`,
        [sessionId, roomName, endContext.reason, endContext.actorRole, endContext.actorUserId || null, rejoinEligible]
      );
      const { rows } = await q<{
        first_both_joined_at: string | null;
        entitlement_finalized_at: string | null;
        consumption_id: string | null;
        consumption_finalized: boolean | null;
      }>(
        `select v.first_both_joined_at::text,
                v.entitlement_finalized_at::text,
                ec.id as consumption_id,
                ec.finalized as consumption_finalized
           from video_session_lifecycle v
      left join lateral (
            select id, finalized
              from entitlement_consumptions
             where session_id = v.session_id
               and consumption_type = 'video'
               and canceled_at is null
             order by created_at desc
             limit 1
           ) ec on true
          where v.session_id = $1::uuid
          limit 1`,
        [sessionId]
      );
      const state = rows[0];
      const engaged = !!state?.first_both_joined_at || state?.consumption_finalized === true || !!state?.entitlement_finalized_at;
      let entitlementAction = 'none';
      if (state?.consumption_id && engaged && !state.consumption_finalized) {
        const { rows: committed } = await q<{ ok: boolean }>(`select fn_commit_consumption($1::uuid) as ok`, [state.consumption_id]);
        if (committed[0]?.ok) entitlementAction = 'committed';
      } else if (state?.consumption_id && !engaged) {
        const { rows: released } = await q<{ ok: boolean }>(`select fn_release_consumption($1::uuid) as ok`, [state.consumption_id]);
        if (released[0]?.ok) entitlementAction = 'released';
      }
      await q(
        `update video_session_lifecycle
            set status = $2,
                room_finished_at = coalesce(room_finished_at, now()),
                entitlement_consumption_id = coalesce(entitlement_consumption_id, $3::uuid),
                entitlement_finalized_at = case when $4 then coalesce(entitlement_finalized_at, now()) else entitlement_finalized_at end,
                entitlement_released_at = case when $5 then coalesce(entitlement_released_at, now()) else entitlement_released_at end,
                safety_reason = $6,
                end_reason = $6,
                end_actor_role = $7,
                end_actor_user_id = $8::uuid,
                rejoin_eligible_until = case when $9 then coalesce(rejoin_eligible_until, now() + interval '10 minutes') else rejoin_eligible_until end,
                updated_at = now()
          where session_id = $1::uuid`,
        [sessionId, engaged ? 'ended' : 'released', state?.consumption_id || null, entitlementAction === 'committed', entitlementAction === 'released', endContext.reason, endContext.actorRole, endContext.actorUserId || null, rejoinEligible]
      );
      await q(`select fn_release_vet_consult_lock($1::uuid, $2)`, [sessionId, endContext.reason]);
      const settlement = { action: entitlementAction, reason: endContext.reason, endedByRole: endContext.actorRole, settled: true };
      this.roadmapLog('room.ended.settled', {
        sessionId,
        roomName,
        reason: endContext.reason,
        actorRole: endContext.actorRole,
        engaged,
        entitlementAction,
        rejoinEligible,
      });
      return settlement;
    });
  }

  private normalizeVideoEndReason(value: unknown, actorRole: VideoEndActorRole): VideoEndReason {
    const reason = String(value || '').trim().toLowerCase();
    const allowed = new Set<VideoEndReason>([
      'owner_ended',
      'vet_ended',
      'admin_ended',
      'network_disconnect',
      'timeout_no_show',
      'provider_room_finished',
      'room_end',
      'reconcile_timeout',
    ]);
    if (allowed.has(reason as VideoEndReason)) return reason as VideoEndReason;
    if (actorRole === 'owner') return 'owner_ended';
    if (actorRole === 'vet') return 'vet_ended';
    if (actorRole === 'admin') return 'admin_ended';
    return 'room_end';
  }

  private async getVideoEndState(sessionId: string) {
    if (this.db.isStub) {
      return {
        sessionId,
        sessionStatus: 'active',
        lifecycleStatus: 'ended',
        endedByRole: null,
        endReason: null,
        roomFinishedAt: null,
        rejoinEligible: false,
        rejoinUntil: null,
        recommendedAction: 'chat',
      };
    }
    const { rows } = await this.db.runInTx(async (q) => q<any>(
      `select s.id::text as session_id,
              s.status as session_status,
              s.mode,
              s.user_id::text as user_id,
              s.vet_id::text as vet_id,
              v.status as lifecycle_status,
              v.end_actor_role,
              v.end_actor_user_id::text as end_actor_user_id,
              coalesce(v.end_reason, v.safety_reason) as end_reason,
              v.room_finished_at,
              v.rejoin_eligible_until,
              (v.rejoin_eligible_until is not null and v.rejoin_eligible_until > now()) as within_rejoin_window
         from chat_sessions s
    left join video_session_lifecycle v on v.session_id = s.id
        where s.id = $1::uuid
          and s.mode = 'video'
          and (s.user_id = auth.uid() or s.vet_id = auth.uid() or is_admin())
        limit 1`,
      [sessionId]
    ));
    const row = rows[0];
    if (!row) throw new NotFoundException('video_session_not_found');
    const sessionStatus = String(row.session_status || '').toLowerCase();
    const endReason = row.end_reason || null;
    const rejoinEligible = sessionStatus === 'active'
      && row.within_rejoin_window === true
      && ['owner_ended', 'vet_ended', 'admin_ended'].includes(String(endReason || ''));
    return {
      sessionId: row.session_id,
      sessionStatus: row.session_status,
      lifecycleStatus: row.lifecycle_status || null,
      endedByRole: row.end_actor_role || null,
      endActorUserId: row.end_actor_user_id || null,
      endReason,
      roomFinishedAt: row.room_finished_at || null,
      rejoinEligible,
      rejoinUntil: row.rejoin_eligible_until || null,
      recommendedAction: rejoinEligible ? 'rejoin' : 'chat',
    };
  }

  private normalizeRequestedParticipantRole(value: unknown): LiveKitParticipantRole | null {
    const role = String(value || '').trim().toLowerCase();
    if (role === 'owner' || role === 'vet' || role === 'admin') return role;
    return null;
  }

  private resolveParticipantRole(session: { user_id: string | null; vet_id: string | null }, requestedRole?: unknown): LiveKitParticipantRole {
    const userId = this.rc.requireUuidUserId();
    const requested = this.normalizeRequestedParticipantRole(requestedRole);
    if (requested === 'owner') {
      if (session.user_id === userId) return 'owner';
      throw new ForbiddenException('video_owner_role_not_allowed');
    }
    if (requested === 'vet') {
      if (session.vet_id === userId) return 'vet';
      throw new ForbiddenException('video_vet_role_not_allowed');
    }
    if (requested === 'admin') {
      if (this.rc.isAdmin) return 'admin';
      throw new ForbiddenException('video_admin_role_not_allowed');
    }
    if (session.vet_id === userId) return 'vet';
    if (session.user_id === userId) return 'owner';
    if (this.rc.isAdmin) return 'admin';
    return 'participant';
  }

  private rawBodyFromRequest(req: Request, body: unknown): string {
    const rawBody = (req as any).rawBody;
    if (Buffer.isBuffer(rawBody)) return rawBody.toString('utf8');
    if (typeof rawBody === 'string') return rawBody;
    if (typeof body === 'string') return body;
    throw new BadRequestException('raw_webhook_body_required');
  }

  private safeParseJson(rawBody: string): Record<string, any> {
    try {
      const parsed = JSON.parse(rawBody);
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch {
      return {};
    }
  }

  private parseMetadata(metadata?: string | null): Record<string, any> {
    if (!metadata) return {};
    try {
      const parsed = JSON.parse(metadata);
      return parsed && typeof parsed === 'object' ? parsed : {};
    } catch {
      return {};
    }
  }

  private isUuid(value: string | null | undefined): value is string {
    return !!value && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
  }

  private webhookRoomName(event: any, payload: Record<string, any>): string | null {
    return event?.room?.name || payload.room?.name || payload.room_name || null;
  }

  private webhookRoomSid(event: any, payload: Record<string, any>): string | null {
    return event?.room?.sid || payload.room?.sid || payload.room_sid || null;
  }

  private webhookParticipantIdentity(event: any, payload: Record<string, any>): string | null {
    return event?.participant?.identity || payload.participant?.identity || payload.participant_identity || null;
  }

  private webhookParticipantSid(event: any, payload: Record<string, any>): string | null {
    return event?.participant?.sid || payload.participant?.sid || payload.participant_sid || null;
  }

  private webhookSessionId(event: any, payload: Record<string, any>, roomName: string | null): string | null {
    const roomMetadata = this.parseMetadata(event?.room?.metadata || payload.room?.metadata);
    const participantMetadata = this.parseMetadata(event?.participant?.metadata || payload.participant?.metadata);
    const candidate = roomMetadata.sessionId || participantMetadata.sessionId || payload.sessionId || (roomName ? this.livekit.sessionIdFromRoomName(roomName) : null);
    const sessionId = candidate ? String(candidate) : null;
    return this.isUuid(sessionId) ? sessionId : null;
  }

  private webhookParticipantRole(event: any, payload: Record<string, any>, participantIdentity: string | null): LiveKitParticipantRole {
    const participantMetadata = this.parseMetadata(event?.participant?.metadata || payload.participant?.metadata);
    const role = String(participantMetadata.role || '').toLowerCase();
    if (role === 'owner' || role === 'vet' || role === 'admin') return role as LiveKitParticipantRole;
    if (participantIdentity?.startsWith('owner:')) return 'owner';
    if (participantIdentity?.startsWith('vet:')) return 'vet';
    if (participantIdentity?.startsWith('admin:')) return 'admin';
    return 'participant';
  }

  private egressId(payload: Record<string, any>): string | null {
    return payload.egressInfo?.egressId || payload.egress_info?.egress_id || null;
  }

  private recordingUrl(payload: Record<string, any>): string | null {
    const fileResults = payload.egressInfo?.fileResults || payload.egress_info?.file_results;
    if (Array.isArray(fileResults) && fileResults.length > 0) {
      return fileResults[0]?.location || fileResults[0]?.filename || null;
    }
    return null;
  }

  private async ensureLifecycle(q: TxQuery, sessionId: string, roomName: string | null, roomSid: string | null) {
    await q(
      `insert into video_session_lifecycle (session_id, room_name, room_sid, status, created_at, updated_at)
       values ($1::uuid, $2, $3, 'pending', now(), now())
       on conflict (session_id) do update
         set room_name = coalesce(excluded.room_name, video_session_lifecycle.room_name),
             room_sid = coalesce(excluded.room_sid, video_session_lifecycle.room_sid),
             updated_at = now()`,
      [sessionId, roomName, roomSid]
    );
  }

  private async findConsumptionState(q: TxQuery, sessionId: string) {
    const { rows } = await q<{
      owner_joined_at: string | null;
      host_joined_at: string | null;
      first_both_joined_at: string | null;
      entitlement_consumption_id: string | null;
      consumption_id: string | null;
      consumption_finalized: boolean | null;
    }>(
      `select v.owner_joined_at::text,
              v.host_joined_at::text,
              v.first_both_joined_at::text,
              v.entitlement_consumption_id,
              coalesce(v.entitlement_consumption_id, ec.id) as consumption_id,
              ec.finalized as consumption_finalized
         from video_session_lifecycle v
    left join lateral (
          select id, finalized
            from entitlement_consumptions
           where session_id = v.session_id
             and consumption_type = 'video'
             and canceled_at is null
           order by created_at desc
           limit 1
         ) ec on true
        where v.session_id = $1::uuid
        limit 1`,
      [sessionId]
    );
    return rows[0];
  }

  private async commitIfBothJoined(q: TxQuery, sessionId: string) {
    const state = await this.findConsumptionState(q, sessionId);
    const bothJoined = !!state?.first_both_joined_at || (!!state?.owner_joined_at && !!state?.host_joined_at);
    if (!bothJoined) return 'none';
    let action = 'none';
    if (state?.consumption_id && !state.consumption_finalized) {
      const { rows } = await q<{ ok: boolean }>(`select fn_commit_consumption($1::uuid) as ok`, [state.consumption_id]);
      action = rows[0]?.ok ? 'committed' : 'none';
    }
    await q(
      `update video_session_lifecycle
          set status = 'live',
              first_both_joined_at = coalesce(first_both_joined_at, now()),
              entitlement_consumption_id = coalesce(entitlement_consumption_id, $2::uuid),
              entitlement_finalized_at = coalesce(entitlement_finalized_at, now()),
              updated_at = now()
        where session_id = $1::uuid`,
      [sessionId, state?.consumption_id || null]
    );
    return action;
  }

  private async settleFinishedLifecycle(q: TxQuery, sessionId: string, reason: VideoEndReason, endContext: Partial<VideoEndContext> = {}) {
    const state = await this.findConsumptionState(q, sessionId);
    const engaged = !!state?.first_both_joined_at || (!!state?.owner_joined_at && !!state?.host_joined_at) || state?.consumption_finalized === true;
    let entitlementAction = 'none';
    if (state?.consumption_id && engaged && !state.consumption_finalized) {
      const { rows } = await q<{ ok: boolean }>(`select fn_commit_consumption($1::uuid) as ok`, [state.consumption_id]);
      entitlementAction = rows[0]?.ok ? 'committed' : 'none';
    } else if (state?.consumption_id && !engaged) {
      const { rows } = await q<{ ok: boolean }>(`select fn_release_consumption($1::uuid) as ok`, [state.consumption_id]);
      entitlementAction = rows[0]?.ok ? 'released' : 'none';
    }
    await q(
      `update video_session_lifecycle
          set status = case when $2 then 'ended' else case when $6 in ('reconcile_timeout', 'timeout_no_show') then 'timed_out' else 'released' end end,
              room_finished_at = coalesce(room_finished_at, now()),
              entitlement_consumption_id = coalesce(entitlement_consumption_id, $3::uuid),
              entitlement_finalized_at = case when $4 then coalesce(entitlement_finalized_at, now()) else entitlement_finalized_at end,
              entitlement_released_at = case when $5 then coalesce(entitlement_released_at, now()) else entitlement_released_at end,
              safety_reason = case when $2 then safety_reason else $6 end,
              end_reason = coalesce(end_reason, $6),
              end_actor_role = coalesce(end_actor_role, $7),
              end_actor_user_id = coalesce(end_actor_user_id, $8::uuid),
              updated_at = now()
        where session_id = $1::uuid`,
      [sessionId, engaged, state?.consumption_id || null, entitlementAction === 'committed' || (engaged && !!state?.consumption_id), entitlementAction === 'released', reason, endContext.actorRole || 'system', endContext.actorUserId || null]
    );
    await q(
      `update chat_sessions
          set status = case when $2 then 'completed' else 'canceled' end,
              ended_at = coalesce(ended_at, now()),
              updated_at = now()
        where id = $1::uuid`,
      [sessionId, engaged]
    );
    await q(
      `update appointments
          set status = case when $2 then 'completed' else case when status = 'completed' then status else 'no_show' end end
        where session_id = $1::uuid`,
      [sessionId, engaged]
    );
    await q(
      `update clinical_encounters
          set status = 'closed',
              ended_at = coalesce(ended_at, now()),
              updated_at = now()
        where session_id = $1::uuid`,
      [sessionId]
    );
    return { engaged, entitlementAction };
  }

  private async handleLiveKitEvent(event: any, payload: Record<string, any>) {
    const eventType = String(event?.event || payload.event || '').trim();
    const roomName = this.webhookRoomName(event, payload);
    const roomSid = this.webhookRoomSid(event, payload);
    const participantIdentity = this.webhookParticipantIdentity(event, payload);
    const participantSid = this.webhookParticipantSid(event, payload);
    const sessionId = this.webhookSessionId(event, payload, roomName);
    const role = this.webhookParticipantRole(event, payload, participantIdentity);

    if (this.db.isStub) return { eventType, sessionId, action: 'stub' };

    return this.db.runInTx(async (q) => {
      const { rows: eventRows } = await q<{ id: string }>(
        `insert into livekit_video_events (event_type, room_name, room_sid, session_id, participant_identity, participant_sid, payload, received_at)
         values ($1, $2, $3, $4::uuid, $5, $6, $7::jsonb, now())
         returning id`,
        [eventType || 'unknown', roomName, roomSid, sessionId, participantIdentity, participantSid, JSON.stringify(payload)]
      );
      const eventId = eventRows[0]?.id;
      let action: any = 'stored';
      if (sessionId) {
        await this.ensureLifecycle(q, sessionId, roomName, roomSid);
        if (eventType === 'room_started') {
          await q(
            `update video_session_lifecycle
                set first_room_started_at = coalesce(first_room_started_at, now()),
                    status = case when status in ('ended', 'released', 'timed_out', 'forced_ended') then status else 'waiting' end,
                    updated_at = now()
              where session_id = $1::uuid`,
            [sessionId]
          );
          action = 'room_started';
        } else if (eventType === 'participant_joined') {
          await q(
            `update video_session_lifecycle
                set first_participant_joined_at = coalesce(first_participant_joined_at, now()),
                    owner_joined_at = case when $2 then coalesce(owner_joined_at, now()) else owner_joined_at end,
                    host_joined_at = case when $3 then coalesce(host_joined_at, now()) else host_joined_at end,
                    status = case when status in ('ended', 'released', 'timed_out', 'forced_ended') then status else 'waiting' end,
                    updated_at = now()
              where session_id = $1::uuid`,
            [sessionId, role === 'owner', role === 'vet' || role === 'admin']
          );
          action = await this.commitIfBothJoined(q, sessionId);
        } else if (eventType === 'participant_left' || eventType === 'participant_connection_aborted') {
          await q(
            `update video_session_lifecycle
                set last_participant_left_at = now(),
                    safety_reason = case when $2 then 'participant_connection_aborted' else safety_reason end,
                    updated_at = now()
              where session_id = $1::uuid`,
            [sessionId, eventType === 'participant_connection_aborted']
          );
          action = eventType;
        } else if (eventType === 'room_finished') {
          action = await this.settleFinishedLifecycle(q, sessionId, 'provider_room_finished', { actorRole: 'system', reason: 'provider_room_finished' });
        } else if (eventType === 'egress_started' || eventType === 'egress_updated' || eventType === 'egress_ended') {
          await q(
            `update video_session_lifecycle
                set egress_id = coalesce($2, egress_id),
                    egress_started_at = case when $3 then coalesce(egress_started_at, now()) else egress_started_at end,
                    egress_ended_at = case when $4 then coalesce(egress_ended_at, now()) else egress_ended_at end,
                    recording_url = coalesce($5, recording_url),
                    updated_at = now()
              where session_id = $1::uuid`,
            [sessionId, this.egressId(payload), eventType === 'egress_started', eventType === 'egress_ended', this.recordingUrl(payload)]
          );
          action = eventType;
        }
      }
      if (eventId) {
        await q(
          `update livekit_video_events
              set processed_at = now(), processing_error = null
            where id = $1::uuid`,
          [eventId]
        );
      }
      this.roadmapLog('livekit.webhook.processed', {
        eventId,
        eventType,
        sessionId,
        roomName,
        participantRole: role,
        action,
      });
      return { eventId, eventType, sessionId, roomName, action };
    });
  }

  @Post('rooms')
  @UseGuards(AuthGuard, EndpointRateLimitGuard)
  @RateLimit({ key: 'video.rooms.create', limit: 10, windowMs: 60_000 })
  async createRoom(@Body() body: { sessionId?: string; participantRole?: string; role?: string }) {
    const sessionId = (body?.sessionId || '').toString().trim();
    if (!sessionId) throw new BadRequestException('sessionId is required');
    this.validator.validateUUID(sessionId, 'sessionId');
    const session = await this.getAuthorizedVideoSession(sessionId);
    this.assertVideoSessionCanJoin(session);
    const role = this.resolveParticipantRole(session, body?.participantRole || body?.role);
    const consumptionId = await this.ensureVideoEntitlementReservation(session, role);
    const userId = this.rc.requireUuidUserId();
    const roomName = this.livekit.roomNameForSession(sessionId);
    const identity = `${role}:${userId}`;
    const metadata = { sessionId, userId, role };

    await this.livekit.ensureRoom(roomName, metadata);
    await this.markRoomProvisioned(sessionId, roomName, consumptionId);
    const token = await this.livekit.createJoinToken({
      roomName,
      identity,
      name: `${role}-${userId.slice(0, 8)}`,
      role,
      metadata,
    });

    this.roadmapLog('room.create.succeeded', {
      sessionId,
      roomName,
      role,
      userId,
      consumptionId,
    });

    return {
      provider: 'livekit',
      roomId: roomName,
      roomName,
      sessionId,
      token,
      url: this.livekit.publicUrl,
      identity,
      role,
      expiresIn: 3600,
      entitlement: {
        consumptionId,
        status: 'reserved',
      },
    };
  }

  @Post('rooms/:roomId/end')
  @UseGuards(AuthGuard)
  async endRoom(@Param('roomId') roomId: string, @Body() body: { participantRole?: string; role?: string; reason?: string } = {}) {
    const normalizedRoomId = String(roomId || '').trim();
    if (!normalizedRoomId) throw new BadRequestException('roomId is required');
    const sessionId = this.livekit.sessionIdFromRoomName(normalizedRoomId);
    this.validator.validateUUID(sessionId, 'sessionId');
    const session = await this.getAuthorizedVideoSession(sessionId);
    const actorRole = this.resolveParticipantRole(session, body?.participantRole || body?.role);
    const actorUserId = this.rc.requireUuidUserId();
    const reason = this.normalizeVideoEndReason(body?.reason, actorRole);
    this.roadmapLog('room.end.requested', { sessionId, roomName: normalizedRoomId, actorRole, reason });
    const result = await this.livekit.endRoom(normalizedRoomId);
    const settlement = await this.markVideoRoomEnded(sessionId, normalizedRoomId, { actorRole, actorUserId, reason });
    const endState = await this.getVideoEndState(sessionId);
    this.roadmapLog('room.end.completed', {
      sessionId,
      roomName: normalizedRoomId,
      actorRole,
      reason,
      settlementAction: settlement.action,
      endStateReason: endState.endReason,
      rejoinEligible: endState.rejoinEligible,
    });
    return { ok: true, provider: 'livekit', roomId: normalizedRoomId, ...result, settlement, endState };
  }

  @Get('sessions/:sessionId/end-state')
  @UseGuards(AuthGuard)
  async endState(@Param('sessionId') sessionId: string) {
    const normalizedSessionId = String(sessionId || '').trim();
    if (!normalizedSessionId) throw new BadRequestException('sessionId is required');
    this.validator.validateUUID(normalizedSessionId, 'sessionId');
    const state = await this.getVideoEndState(normalizedSessionId);
    this.roadmapLog('end_state.read', {
      sessionId: normalizedSessionId,
      lifecycleStatus: state.lifecycleStatus,
      endReason: state.endReason,
      endedByRole: state.endedByRole,
      rejoinEligible: state.rejoinEligible,
      recommendedAction: state.recommendedAction,
    });
    return { ok: true, ...state };
  }

  @Post('sessions/:sessionId/post-call-message')
  @UseGuards(AuthGuard, EndpointRateLimitGuard)
  @RateLimit({ key: 'video.post_call_message', limit: 6, windowMs: 60_000 })
  async postCallMessage(@Param('sessionId') sessionId: string, @Body() body: { endState?: Record<string, any> } = {}) {
    const normalizedSessionId = String(sessionId || '').trim();
    if (!normalizedSessionId) throw new BadRequestException('sessionId is required');
    this.validator.validateUUID(normalizedSessionId, 'sessionId');
    const endState = body?.endState && typeof body.endState === 'object' ? body.endState : await this.getVideoEndState(normalizedSessionId);
    this.roadmapLog('post_call_message.requested', {
      sessionId: normalizedSessionId,
      endReason: endState?.endReason || null,
      rejoinEligible: endState?.rejoinEligible === true,
    });
    const result = await this.ai.generateVideoPostCallMessage({ sessionId: normalizedSessionId, endState });
    this.roadmapLog('post_call_message.completed', {
      sessionId: normalizedSessionId,
      eventId: result.eventId,
      provider: result.provider,
      suggestedAction: result.payload?.suggestedAction || null,
      rejoinRecommended: result.payload?.rejoinRecommended === true,
    });
    return { ok: true, ...result };
  }

  private async processLiveKitWebhook(req: Request, body: unknown, authorization?: string, authorize?: string) {
    const rawBody = this.rawBodyFromRequest(req, body);
    let event: any;
    try {
      event = await this.livekit.receiveWebhook(rawBody, authorization || authorize);
    } catch {
      throw new UnauthorizedException('invalid_livekit_webhook_signature');
    }
    const payload = this.safeParseJson(rawBody);
    const result = await this.handleLiveKitEvent(event, payload);
    return { ok: true, provider: 'livekit', ...result };
  }

  @Post('livekit/webhook')
  async liveKitWebhook(
    @Req() req: Request,
    @Body() body: unknown,
    @Headers('authorization') authorization?: string,
    @Headers('authorize') authorize?: string,
  ) {
    return this.processLiveKitWebhook(req, body, authorization, authorize);
  }

  @Post('webhooks/livekit')
  async liveKitWebhookAlias(
    @Req() req: Request,
    @Body() body: unknown,
    @Headers('authorization') authorization?: string,
    @Headers('authorize') authorize?: string,
  ) {
    return this.processLiveKitWebhook(req, body, authorization, authorize);
  }

  @Post('reconcile')
  async reconcile(@Headers('x-internal-secret') secret?: string, @Body() body?: { maxAgeMinutes?: number; limit?: number }) {
    const expected = (process.env.INTERNAL_LIVEKIT_RECONCILE_SECRET || '').trim();
    if (!expected) throw new HttpException('reconcile_not_configured', HttpStatus.SERVICE_UNAVAILABLE);
    if (!secret || secret !== expected) throw new UnauthorizedException('invalid_reconcile_secret');
    const maxAgeMinutes = Math.min(Math.max(Number(body?.maxAgeMinutes || 20), 5), 240);
    const limit = Math.min(Math.max(Number(body?.limit || 25), 1), 100);
    if (this.db.isStub) return { ok: true, provider: 'livekit', reconciled: 0, rows: [] };

    const { rows } = await this.db.query<{ session_id: string; room_name: string | null }>(
      `select session_id, room_name
         from video_session_lifecycle
        where status in ('pending', 'waiting')
          and first_both_joined_at is null
          and created_at < now() - ($1::text || ' minutes')::interval
        order by created_at asc
        limit $2`,
      [String(maxAgeMinutes), limit]
    );
    const settled: any[] = [];
    for (const row of rows) {
      if (row.room_name) {
        try { await this.livekit.endRoom(row.room_name); } catch {}
      }
      const result = await this.db.runInTx(async (q) => this.settleFinishedLifecycle(q, row.session_id, 'timeout_no_show', { actorRole: 'system', reason: 'timeout_no_show' }));
      settled.push({ sessionId: row.session_id, roomName: row.room_name, ...result });
    }
    return { ok: true, provider: 'livekit', reconciled: settled.length, rows: settled };
  }
}
