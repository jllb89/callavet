import { Body, Controller, HttpException, HttpStatus, Post, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';

@Controller('sessions')
@UseGuards(AuthGuard)
export class SessionsController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

  @Post('start')
  async start(@Body() body: { userId?: string; kind?: 'chat'|'video'; sessionId?: string }) {
    try {
      const kind = body.kind || 'chat';
      if (this.db.isStub) {
        const sessionId = body.sessionId || `sess_${Date.now()}`;
        return { ok: true, mode: 'stub', sessionId, kind };
      }
      const result = await this.db.runInTx(async (q) => {
        // 1) Create session first (FK target) using auth.uid() for user_id
        const { rows: r2 } = await q<{ id: string }>(
          `insert into chat_sessions (id, user_id, status, started_at)
           values (gen_random_uuid(), auth.uid(), $1, now())
           returning id`,
          ['active']
        );
        const dbSessionId = r2?.[0]?.id as string;
        // 2) Reserve entitlement referencing the created session id
        const reserveFn = kind === 'video' ? 'fn_reserve_video' : 'fn_reserve_chat';
        const { rows: r1 } = await q<{ consumption_id: string }>(
          `select * from ${reserveFn}(auth.uid(), trim($1)::uuid)`,
          [dbSessionId]
        );
        const consumptionId = (r1?.[0] as any)?.consumption_id as string | undefined;
        return { dbSessionId, consumptionId };
      });
      return { ok: true, sessionId: result.dbSessionId, consumptionId: result.consumptionId, kind };
    } catch (e: any) {
      throw new HttpException(e?.message || 'start_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('end')
  async end(@Body() body: { sessionId: string; consumptionId?: string }) {
    try {
      if (this.db.isStub) return { ok: true, mode: 'stub', sessionId: body.sessionId, ended: true };
      await this.db.runInTx(async (q) => {
        await q('update chat_sessions set ended_at = now(), status = $2 where id = $1', [body.sessionId, 'completed']);
        if (body.consumptionId) {
          await q('select fn_commit_consumption($1) as ok', [body.consumptionId]);
        }
      });
      return { ok: true, sessionId: body.sessionId, ended: true };
    } catch (e: any) {
      throw new HttpException(e?.message || 'end_failed', HttpStatus.BAD_REQUEST);
    }
  }
}
