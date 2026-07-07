import { Body, Controller, Get, Headers, HttpException, HttpStatus, Param, Post, Query, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';
import { EndpointRateLimitGuard } from '../rate-limit/endpoint-rate-limit.guard';
import { RateLimit } from '../rate-limit/rate-limit.decorator';

type TxQuery = <R = any>(sql: string, args?: any[]) => Promise<{ rows: R[] }>;

type SessionMessageBody = {
  role?: string;
  content?: string;
  clientKey?: string;
  client_key?: string;
};

type SessionMessageReadBody = {
  lastStreamOrder?: string | number;
};

type SessionMessageAccess = {
  id: string;
  status: string | null;
  mode: string | null;
  actor_role: 'user' | 'vet' | 'admin';
  consumption_id: string | null;
  consumption_finalized: boolean | null;
};

type SessionMessageRow = {
  id: string;
  session_id: string;
  sender_id: string;
  role: string;
  content: string;
  client_key: string | null;
  stream_order: string | number;
  created_at: string;
  edited_at: string | null;
  deleted_at: string | null;
  redacted_at: string | null;
  redaction_reason: string | null;
};

@Controller('sessions')
@UseGuards(AuthGuard)
export class SessionMessagesController {
  constructor(private readonly db: DbService) {}

  private normalizeActorHint(value?: string | string[]) {
    const raw = Array.isArray(value) ? value[0] : value;
    const normalized = String(raw || '').trim().toLowerCase();
    return normalized === 'vet' || normalized === 'user' ? normalized : null;
  }

  private realtimeLog(event: string, metadata: Record<string, any> = {}) {
    console.log(JSON.stringify({
      scope: 'chat_consultation_realtime',
      component: 'session_messages',
      event,
      at: new Date().toISOString(),
      ...metadata,
    }));
  }

  private async getSessionAccess(q: TxQuery, sessionId: string, actorHint?: 'user' | 'vet' | null) {
    const { rows } = await q<SessionMessageAccess>(
      `select s.id,
              s.status,
              s.mode,
              case
                when s.user_id = auth.uid() and s.vet_id = auth.uid() and $2::text = 'vet' then 'vet'
                when s.user_id = auth.uid() then 'user'
                when s.vet_id = auth.uid() then 'vet'
                else 'admin'
              end::text as actor_role,
              (
                select ec.id
                  from entitlement_consumptions ec
                 where ec.session_id = s.id
                   and ec.canceled_at is null
                 order by ec.created_at desc
                 limit 1
              ) as consumption_id,
              (
                select ec.finalized
                  from entitlement_consumptions ec
                 where ec.session_id = s.id
                   and ec.canceled_at is null
                 order by ec.created_at desc
                 limit 1
              ) as consumption_finalized
         from chat_sessions s
        where s.id = $1::uuid
          and (s.user_id = auth.uid() or s.vet_id = auth.uid() or is_admin())
        limit 1`,
      [sessionId, actorHint || null]
    );
    return rows[0] || null;
  }

  private normalizeMessage(row: SessionMessageRow) {
    return {
      ...row,
      stream_order: Number(row.stream_order || 0),
    };
  }

  private async markSenderRead(q: TxQuery, messageId: string) {
    await q(
      `insert into message_receipts (message_id, user_id, delivered_at, read_at)
       values ($1::uuid, auth.uid(), now(), now())
       on conflict (message_id, user_id)
       do update set delivered_at = coalesce(message_receipts.delivered_at, excluded.delivered_at),
                     read_at = coalesce(message_receipts.read_at, excluded.read_at)`,
      [messageId]
    );
  }

  private async emitRoomBroadcast(q: TxQuery, sessionId: string, event: string, payload: Record<string, any>) {
    await q(
      `select public.fn_emit_consult_room_broadcast($1::uuid, $2::text, $3::jsonb)`,
      [sessionId, event, JSON.stringify(payload)]
    );
  }

  private async commitConsumptionIfNeeded(q: TxQuery, session: SessionMessageAccess) {
    if (!session.consumption_id || session.consumption_finalized === true) return false;
    const { rows } = await q<{ ok: boolean }>(
      `select fn_commit_consumption($1::uuid) as ok`,
      [session.consumption_id]
    );
    return rows[0]?.ok === true;
  }

  @Get(':sessionId/messages')
  async list(
    @Param('sessionId') sessionId: string,
    @Headers('x-cav-actor-role') actorRoleHeader?: string | string[],
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string,
    @Query('since') since?: string,
    @Query('until') until?: string,
    @Query('sort') sort?: string,
    @Query('includeDeleted') includeDeletedStr?: string,
    @Query('afterStreamOrder') afterStreamOrderStr?: string,
  ) {
    try {
      const limit = Math.min(Math.max(parseInt(limitStr || '50', 10) || 50, 1), 200);
      const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
      if (this.db.isStub) {
        return { ok: true, sessionId, cursor: 0, items: [], receipts: [], mode: 'stub' } as any;
      }
      const actorHint = this.normalizeActorHint(actorRoleHeader);
      const result = await this.db.runInTx(async (q) => {
        const session = await this.getSessionAccess(q, sessionId, actorHint);
        if (!session) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
        const includeDeleted = ['1','true','yes'].includes((includeDeletedStr || '').toLowerCase());
        const filters: string[] = ['session_id = $1::uuid'];
        const args: any[] = [sessionId];
        let idx = 2;
        filters.push(`((( ${includeDeleted ? 'true' : 'false'} ) = true AND is_admin()) OR deleted_at IS NULL)`);
        const afterStreamOrder = Number(afterStreamOrderStr || 0);
        if (Number.isFinite(afterStreamOrder) && afterStreamOrder > 0) {
          filters.push(`stream_order > $${idx++}`);
          args.push(Math.floor(afterStreamOrder));
        }
        if (since) {
          const d = new Date(since); if (!isNaN(d.getTime())) { filters.push(`created_at >= $${idx++}`); args.push(d.toISOString()); }
        }
        if (until) {
          const d = new Date(until); if (!isNaN(d.getTime())) { filters.push(`created_at <= $${idx++}`); args.push(d.toISOString()); }
        }
        let order = 'stream_order asc';
        if (sort) {
          const v = sort.toLowerCase();
          if (v === 'created_at.asc') order = 'created_at asc';
          else if (v === 'created_at.desc') order = 'created_at desc';
          else if (v === 'stream_order.asc') order = 'stream_order asc';
          else if (v === 'stream_order.desc') order = 'stream_order desc';
        }
        const where = 'where ' + filters.join(' and ');
        const { rows } = await q<SessionMessageRow>(
          `select id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason
             from messages
             ${where}
            order by ${order}
            limit $${idx} offset $${idx+1}`,
          [...args, limit, offset]
        );
        const messageIds = rows.map((row) => row.id);
        const receipts = messageIds.length
          ? (await q(
              `select message_id, user_id, delivered_at, read_at
                 from message_receipts
                where message_id = any($1::uuid[])
                order by delivered_at asc nulls last, read_at asc nulls last`,
              [messageIds]
            )).rows
          : [];
        const items = rows.map((row) => this.normalizeMessage(row));
        const cursor = items.length ? items[items.length - 1].stream_order : 0;
        return { session, items, receipts, cursor };
      });
      this.realtimeLog('messages.sync.completed', {
        sessionId,
        role: result.session.actor_role,
        status: result.session.status,
        count: result.items.length,
        receiptCount: result.receipts.length,
        cursor: result.cursor,
        afterStreamOrder: afterStreamOrderStr || null,
      });
      return {
        ok: true,
        sessionId,
        session: {
          id: result.session.id,
          status: result.session.status,
          mode: result.session.mode,
          role: result.session.actor_role,
        },
        cursor: result.cursor,
        items: result.items,
        receipts: result.receipts,
        sort: sort || 'stream_order.asc',
        since: since || null,
        until: until || null,
        afterStreamOrder: afterStreamOrderStr || null,
        includeDeleted: !!includeDeletedStr,
      };
    } catch (e: any) {
      this.realtimeLog('messages.sync.failed', {
        sessionId,
        error: e?.message || 'list_failed',
      });
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'list_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post(':sessionId/messages')
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'sessions.messages.create', limit: 30, windowMs: 60_000 })
  async create(
    @Param('sessionId') sessionId: string,
    @Headers('x-cav-actor-role') actorRoleHeader: string | string[] | undefined,
    @Body() body: SessionMessageBody,
  ) {
    try {
      const content = (body?.content || '').toString().trim();
      const clientKey = (body?.clientKey || body?.client_key || '').toString().trim() || null;
      const actorHint = this.normalizeActorHint(actorRoleHeader);
      if (!content) {
        throw new HttpException('content_required', HttpStatus.BAD_REQUEST);
      }
      if (content.length > 4000) {
        throw new HttpException('content_too_long', HttpStatus.BAD_REQUEST);
      }
      if (clientKey && clientKey.length > 128) {
        throw new HttpException('client_key_too_long', HttpStatus.BAD_REQUEST);
      }
      if (this.db.isStub) {
        return {
          ok: true,
          sessionId,
          duplicate: false,
          committed: false,
          message: { id: `msg_${Date.now()}`, role: 'user', content, client_key: clientKey, stream_order: Date.now(), created_at: new Date().toISOString(), stub: true }
        } as any;
      }
      const result = await this.db.runInTx(async (q) => {
        const session = await this.getSessionAccess(q, sessionId, actorHint);
        if (!session) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
        if (session.actor_role === 'admin') throw new HttpException('admin_send_not_supported', HttpStatus.FORBIDDEN);
        const status = String(session.status || '').toLowerCase();
        if (status === 'pending_payment') throw new HttpException('payment_required', HttpStatus.PAYMENT_REQUIRED);
        if (status !== 'active') throw new HttpException('session_not_active', HttpStatus.CONFLICT);

        if (clientKey) {
          const { rows: existingRows } = await q<SessionMessageRow>(
            `select id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason
               from messages
              where session_id = $1::uuid
                and client_key = $2
              limit 1`,
            [sessionId, clientKey]
          );
          if (existingRows[0]) {
            await this.markSenderRead(q, existingRows[0].id);
            const committed = await this.commitConsumptionIfNeeded(q, session);
            return { message: this.normalizeMessage(existingRows[0]), duplicate: true, committed };
          }
        }

        const { rows } = await q<SessionMessageRow>(
          `insert into messages (id, session_id, sender_id, role, content, client_key, created_at)
           values (gen_random_uuid(), $1::uuid, auth.uid(), $2::text, $3::text, $4::text, now())
           returning id, session_id, sender_id, role, content, client_key, stream_order, created_at, edited_at, deleted_at, redacted_at, redaction_reason`,
          [sessionId, session.actor_role, content, clientKey]
        );
        const inserted = rows[0];
        if (!inserted) throw new HttpException('create_failed', HttpStatus.BAD_REQUEST);
        await q(
          `update chat_sessions
              set updated_at = now()
            where id = $1::uuid`,
          [sessionId]
        );
        const committed = await this.commitConsumptionIfNeeded(q, session);
        await this.markSenderRead(q, inserted.id);
        const message = this.normalizeMessage(inserted);
        await this.emitRoomBroadcast(q, sessionId, 'messages', { sessionId, message });
        return { message, duplicate: false, committed };
      });
      this.realtimeLog('messages.send.completed', {
        sessionId,
        messageId: result.message?.id || null,
        role: result.message?.role || null,
        streamOrder: result.message?.stream_order || null,
        clientKeyPresent: !!clientKey,
        duplicate: result.duplicate === true,
        committed: result.committed === true,
      });
      return { ok: true, sessionId, ...result };
    } catch (e: any) {
      this.realtimeLog('messages.send.failed', {
        sessionId,
        clientKeyPresent: !!(body?.clientKey || body?.client_key),
        contentLength: (body?.content || '').toString().trim().length,
        error: e?.message || 'create_failed',
      });
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'create_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post(':sessionId/messages/read')
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'sessions.messages.read', limit: 60, windowMs: 60_000 })
  async markRead(
    @Param('sessionId') sessionId: string,
    @Headers('x-cav-actor-role') actorRoleHeader: string | string[] | undefined,
    @Body() body: SessionMessageReadBody,
  ) {
    try {
      const lastStreamOrder = Math.max(Number(body?.lastStreamOrder || 0) || 0, 0);
      if (!Number.isFinite(lastStreamOrder) || lastStreamOrder <= 0) {
        throw new HttpException('last_stream_order_required', HttpStatus.BAD_REQUEST);
      }
      if (this.db.isStub) {
        return { ok: true, sessionId, marked: 0, mode: 'stub' } as any;
      }
      const actorHint = this.normalizeActorHint(actorRoleHeader);
      const result = await this.db.runInTx(async (q) => {
        const session = await this.getSessionAccess(q, sessionId, actorHint);
        if (!session) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
        if (session.actor_role === 'admin') throw new HttpException('admin_read_not_supported', HttpStatus.FORBIDDEN);
        const { rows } = await q<{ message_id: string; user_id: string; delivered_at: string; read_at: string }>(
          `with visible_messages as (
             select m.id as message_id
               from messages m
              where m.session_id = $1::uuid
                and m.role <> $3::text
                and m.deleted_at is null
                and m.stream_order <= $2::bigint
           ), upserted as (
             insert into message_receipts (message_id, user_id, delivered_at, read_at)
             select message_id, auth.uid(), now(), now()
               from visible_messages
             on conflict (message_id, user_id)
             do update set delivered_at = coalesce(message_receipts.delivered_at, excluded.delivered_at),
                           read_at = coalesce(message_receipts.read_at, excluded.read_at)
             returning message_id, user_id, delivered_at, read_at
           )
           select message_id, user_id, delivered_at, read_at from upserted`,
          [sessionId, Math.floor(lastStreamOrder), session.actor_role]
        );
        if (rows.length) {
          await this.emitRoomBroadcast(q, sessionId, 'receipts', {
            sessionId,
            receipts: rows.map((row) => ({
              message_id: row.message_id,
              user_id: row.user_id,
              delivered_at: row.delivered_at,
              read_at: row.read_at,
            })),
          });
        }
        return { marked: rows.length };
      });
      this.realtimeLog('messages.read.completed', {
        sessionId,
        lastStreamOrder: Math.floor(lastStreamOrder),
        marked: result.marked,
      });
      return { ok: true, sessionId, ...result };
    } catch (e: any) {
      this.realtimeLog('messages.read.failed', {
        sessionId,
        lastStreamOrder: body?.lastStreamOrder || null,
        error: e?.message || 'mark_read_failed',
      });
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'mark_read_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get(':sessionId/transcript')
  async transcript(@Param('sessionId') sessionId: string, @Query('since') since?: string, @Query('until') until?: string, @Query('includeDeleted') includeDeletedStr?: string) {
    try {
      if (this.db.isStub) return { ok: true, sessionId, transcript: [], mode: 'stub' } as any;
      const rows = await this.db.runInTx(async (q) => {
        const includeDeleted = ['1','true','yes'].includes((includeDeletedStr || '').toLowerCase());
        const filters: string[] = ['session_id = $1', 'deleted_at is null'];
        const args: any[] = [sessionId];
        let idx = 2;
        filters[1] = `( ( ${includeDeleted ? 'true' : 'false'} ) = true AND is_admin() ) OR deleted_at IS NULL`;
        if (since) { const d = new Date(since); if (!isNaN(d.getTime())) { filters.push(`created_at >= $${idx++}`); args.push(d.toISOString()); } }
        if (until) { const d = new Date(until); if (!isNaN(d.getTime())) { filters.push(`created_at <= $${idx++}`); args.push(d.toISOString()); } }
        const where = 'where ' + filters.join(' and ');
        const { rows } = await q(
          `select id, role, content, created_at
             from messages
             ${where}
            order by created_at asc`,
          args
        );
        return rows as any[];
      });
      return { ok: true, sessionId, transcript: rows, since: since || null, until: until || null, includeDeleted: !!includeDeletedStr };
    } catch (e: any) {
      throw new HttpException(e?.message || 'transcript_failed', HttpStatus.BAD_REQUEST);
    }
  }
}