import { BadRequestException, Body, Controller, HttpException, HttpStatus, NotFoundException, Param, Post, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { EndpointRateLimitGuard } from '../rate-limit/endpoint-rate-limit.guard';
import { RateLimit } from '../rate-limit/rate-limit.decorator';
import { ValidatorService } from '../config/validator.service';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { EntitlementService } from '../subscriptions/entitlement.service';
import { LiveKitParticipantRole, LiveKitService } from './livekit.service';

@UseGuards(AuthGuard)
@Controller('video')
export class VideoController {
  constructor(
    private readonly validator: ValidatorService,
    private readonly db: DbService,
    private readonly rc: RequestContext,
    private readonly livekit: LiveKitService,
    private readonly entitlements: EntitlementService,
  ) {}

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
    if (role !== 'owner' && role !== 'admin') {
      throw new HttpException({ ok: false, reason: 'video_entitlement_not_reserved' }, HttpStatus.PAYMENT_REQUIRED);
    }
    if (!session.user_id) throw new BadRequestException('session_owner_missing');
    const result = await this.db.runInTx(async (q) => this.entitlements.reserveForUser(q, 'video', session.user_id!, session.id));
    if (result?.ok && result.consumption_id) return result.consumption_id;
    throw new HttpException({ ok: false, reason: result?.msg || 'video_entitlement_required' }, HttpStatus.PAYMENT_REQUIRED);
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
  }

  private async markForcedEnd(sessionId: string, roomName: string) {
    if (this.db.isStub) return { action: 'stub', reason: 'stub' };
    return this.db.runInTx(async (q) => {
      await q(
        `insert into video_session_lifecycle (session_id, room_name, status, forced_end_at, safety_reason, created_at, updated_at)
         values ($1::uuid, $2, 'forced_ended', now(), 'forced_end', now(), now())
         on conflict (session_id) do update
           set room_name = coalesce(excluded.room_name, video_session_lifecycle.room_name),
               forced_end_at = coalesce(video_session_lifecycle.forced_end_at, now()),
               safety_reason = 'forced_end',
               updated_at = now()`,
        [sessionId, roomName]
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
                safety_reason = 'forced_end',
                updated_at = now()
          where session_id = $1::uuid`,
        [sessionId, engaged ? 'ended' : 'forced_ended', state?.consumption_id || null, entitlementAction === 'committed', entitlementAction === 'released']
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
      return { action: entitlementAction, reason: 'forced_end', settled: true };
    });
  }

  private resolveParticipantRole(session: { user_id: string | null; vet_id: string | null }): LiveKitParticipantRole {
    const userId = this.rc.requireUuidUserId();
    if (session.vet_id === userId) return 'vet';
    if (session.user_id === userId) return 'owner';
    if (this.rc.isAdmin) return 'admin';
    return 'participant';
  }

  @Post('rooms')
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'video.rooms.create', limit: 10, windowMs: 60_000 })
  async createRoom(@Body() body: { sessionId?: string }) {
    const sessionId = (body?.sessionId || '').toString().trim();
    if (!sessionId) throw new BadRequestException('sessionId is required');
    this.validator.validateUUID(sessionId, 'sessionId');
    const session = await this.getAuthorizedVideoSession(sessionId);
    this.assertVideoSessionCanJoin(session);
    const role = this.resolveParticipantRole(session);
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
  async endRoom(@Param('roomId') roomId: string) {
    const normalizedRoomId = String(roomId || '').trim();
    if (!normalizedRoomId) throw new BadRequestException('roomId is required');
    const sessionId = this.livekit.sessionIdFromRoomName(normalizedRoomId);
    this.validator.validateUUID(sessionId, 'sessionId');
    await this.getAuthorizedVideoSession(sessionId);
    const result = await this.livekit.endRoom(normalizedRoomId);
    const settlement = await this.markForcedEnd(sessionId, normalizedRoomId);
    return { ok: true, provider: 'livekit', roomId: normalizedRoomId, ...result, settlement };
  }
}
