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
    @Query('since') since?: string,
    @Query('until') until?: string,
    @Query('sort') sort?: string,
    @Query('includeDeleted') includeDeletedStr?: string,
  ) {
    try {
      const limit = Math.min(Math.max(parseInt(limitStr || '50', 10) || 50, 1), 200);
      const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
      if (this.db.isStub) {
        return { ok: true, sessionId, items: [], mode: 'stub' } as any;
      }
      const rows = await this.db.runInTx(async (q) => {
        const includeDeleted = ['1','true','yes'].includes((includeDeletedStr || '').toLowerCase());
        const filters: string[] = ['session_id = $1'];
        const args: any[] = [sessionId];
        let idx = 2;
        filters.push(`( ( ${includeDeleted ? 'true' : 'false'} ) = true AND is_admin() ) OR deleted_at IS NULL`);
        if (since) {
          const d = new Date(since); if (!isNaN(d.getTime())) { filters.push(`created_at >= $${idx++}`); args.push(d.toISOString()); }
        }
        if (until) {
          const d = new Date(until); if (!isNaN(d.getTime())) { filters.push(`created_at <= $${idx++}`); args.push(d.toISOString()); }
        }
        let order = 'created_at asc';
        if (sort) {
          const v = sort.toLowerCase();
          if (v === 'created_at.asc') order = 'created_at asc';
          else if (v === 'created_at.desc') order = 'created_at desc';
        }
        const where = 'where ' + filters.join(' and ');
        const { rows } = await q(
          `select id, session_id, sender_id, role, content, created_at
             from messages
             ${where}
            order by ${order}
            limit $${idx} offset $${idx+1}`,
          [...args, limit, offset]
        );
        return rows as any[];
      });
      return { ok: true, sessionId, items: rows, sort: sort || 'created_at.asc', since: since || null, until: until || null, includeDeleted: !!includeDeletedStr };
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