import { Body, Controller, Get, HttpException, HttpStatus, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';

@Controller('sessions')
@UseGuards(AuthGuard)
export class SessionsController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

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
      const row = await this.db.runInTx(async (q) => {
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
      return row;
    } catch (e: any) {
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'patch_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('start')
  async start(@Body() body: { userId?: string; kind?: 'chat'|'video'; mode?: 'chat'|'video'; sessionId?: string }) {
    try {
      // Support either `kind` or legacy `mode` field from clients; default chat
      const incoming = (body.kind || body.mode || 'chat')?.toString().toLowerCase();
      const kind: 'chat'|'video' = incoming === 'video' ? 'video' : 'chat';
      if (this.db.isStub) {
        const sessionId = body.sessionId || `sess_${Date.now()}`;
        return { ok: true, mode: 'stub', sessionId, kind };
      }
      const result = await this.db.runInTx(async (q) => {
        // 1) Create session first (FK target) using auth.uid() for user_id
        const { rows: r2 } = await q<{ id: string }>(
          `insert into chat_sessions (id, user_id, status, mode, started_at)
           values (gen_random_uuid(), auth.uid(), $1, $2, now())
           returning id`,
          ['active', kind]
        );
        const dbSessionId = r2?.[0]?.id as string;
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
        const overage = !ok || !consumptionId;
        if (overage) {
          // Mark session as pending_payment for clarity (optional workflow state)
          await q('update chat_sessions set status = $2, updated_at = now() where id = $1', [dbSessionId, 'pending_payment']);
        }
        return { dbSessionId, consumptionId, overage, msg };
      });
      if (result.overage) {
        return {
          ok: true,
          sessionId: result.dbSessionId,
          kind,
          overage: true,
          overageReason: result.msg || 'no_entitlement',
          consumptionId: result.consumptionId || null,
          payment: {
            stub: true,
            status: 'pending',
            type: 'one_off',
            currency: 'usd',
            amount: null,
            reason: result.msg || 'no_entitlement',
          },
        };
      }
      return { ok: true, sessionId: result.dbSessionId, consumptionId: result.consumptionId, kind, overage: false };
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
