import { Body, Controller, Get, HttpException, HttpStatus, Param, Post, Query, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';

@Controller('sessions')
@UseGuards(AuthGuard)
export class SessionMessagesController {
  constructor(private readonly db: DbService) {}

  @Get(':sessionId/messages')
  async list(
    @Param('sessionId') sessionId: string,
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string,
  ) {
    try {
      const limit = Math.min(Math.max(parseInt(limitStr || '50', 10) || 50, 1), 200);
      const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
      if (this.db.isStub) {
        return { ok: true, sessionId, items: [], mode: 'stub' } as any;
      }
      const rows = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `select id, session_id, sender_id, role, content, created_at
             from messages
            where session_id = $1
            order by created_at asc
            limit $2 offset $3`,
          [sessionId, limit, offset]
        );
        return rows as any[];
      });
      return { ok: true, sessionId, items: rows };
    } catch (e: any) {
      throw new HttpException(e?.message || 'list_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post(':sessionId/messages')
  async create(@Param('sessionId') sessionId: string, @Body() body: { role?: string; content?: string }) {
    try {
      const roleRaw = (body?.role || 'user').toString().toLowerCase();
      const role = ['user','vet','ai'].includes(roleRaw) ? roleRaw : 'user';
      const content = (body?.content || '').toString();
      if (!content.trim()) {
        throw new HttpException('content_required', HttpStatus.BAD_REQUEST);
      }
      if (this.db.isStub) {
        return {
          ok: true,
          sessionId,
          message: { id: `msg_${Date.now()}`, role, content, created_at: new Date().toISOString(), stub: true }
        } as any;
      }
      const inserted = await this.db.runInTx(async (q) => {
        const { rows } = await q<{ id: string; created_at: string; role: string; content: string }>(
          `insert into messages (id, session_id, sender_id, role, content, created_at)
           values (gen_random_uuid(), $1::uuid, auth.uid(), $2::text, $3::text, now())
           returning id, session_id, sender_id, role, content, created_at`,
          [sessionId, role, content]
        );
        return rows[0];
      });
      if (!inserted) throw new HttpException('create_failed', HttpStatus.BAD_REQUEST);
      return { ok: true, sessionId, message: inserted };
    } catch (e: any) {
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'create_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get(':sessionId/transcript')
  async transcript(@Param('sessionId') sessionId: string) {
    try {
      if (this.db.isStub) return { ok: true, sessionId, transcript: [], mode: 'stub' } as any;
      const rows = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `select id, role, content, created_at
             from messages
            where session_id = $1
            order by created_at asc`,
          [sessionId]
        );
        return rows as any[];
      });
      return { ok: true, sessionId, transcript: rows };
    } catch (e: any) {
      throw new HttpException(e?.message || 'transcript_failed', HttpStatus.BAD_REQUEST);
    }
  }
}