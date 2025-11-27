import { Body, Controller, Delete, Get, HttpException, HttpStatus, Param, Patch, Query, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';

@Controller('messages')
@UseGuards(AuthGuard)
export class MessagesController {
  constructor(private readonly db: DbService) {}
  @Get()
  async list(
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string,
    @Query('sessionId') sessionId?: string,
    @Query('role') role?: string,
    @Query('senderId') senderId?: string,
    @Query('since') since?: string,
    @Query('until') until?: string,
    @Query('sort') sort?: string,
  ) {
    try {
      const limit = Math.min(Math.max(parseInt(limitStr || '50', 10) || 50, 1), 200);
      const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
      if (this.db.isStub) {
        return { ok: true, mode: 'stub', items: [] } as any;
      }
      const rows = await this.db.runInTx(async (q) => {
        const filters: string[] = ["(s.user_id = auth.uid() or s.vet_id = auth.uid())", "m.deleted_at is null"]; // participant + not deleted
        const args: any[] = [];
        let idx = 1;
        if (sessionId) { filters.push(`m.session_id = $${idx++}`); args.push(sessionId); }
        if (role) { filters.push(`m.role = $${idx++}`); args.push(role.toLowerCase()); }
        if (senderId) { filters.push(`m.sender_id = $${idx++}`); args.push(senderId); }
        let sinceTs: Date | null = null;
        let untilTs: Date | null = null;
        if (since) {
          const d = new Date(since);
            if (!isNaN(d.getTime())) { filters.push(`m.created_at >= $${idx++}`); args.push(d.toISOString()); sinceTs = d; }
        }
        if (until) {
          const d = new Date(until);
            if (!isNaN(d.getTime())) { filters.push(`m.created_at <= $${idx++}`); args.push(d.toISOString()); untilTs = d; }
        }
        let order = 'm.created_at desc';
        if (sort) {
          const v = sort.toLowerCase();
          if (v === 'created_at.asc') order = 'm.created_at asc';
          else if (v === 'created_at.desc') order = 'm.created_at desc';
        }
        const where = filters.length ? 'where ' + filters.join(' and ') : '';
        const { rows } = await q(
          `select m.id, m.session_id, m.sender_id, m.role, m.content, m.created_at
             from messages m
             join chat_sessions s on s.id = m.session_id
             ${where}
            order by ${order}
            limit $${idx} offset $${idx+1}`,
          [...args, limit, offset]
        );
        return rows as any[];
      });
      return { ok: true, items: rows, limit, offset, count: rows.length, sort: sort || 'created_at.desc', since: since || null, until: until || null };
    } catch (e: any) {
      throw new HttpException(e?.message || 'list_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get('transcripts')
  async transcripts(
    @Query('sessionsLimit') sessionsLimitStr?: string,
    @Query('perLimit') perLimitStr?: string,
    @Query('since') since?: string,
    @Query('until') until?: string,
  ) {
    try {
      const sessionsLimit = Math.min(Math.max(parseInt(sessionsLimitStr || '10', 10) || 10, 1), 50);
      const perLimit = Math.min(Math.max(parseInt(perLimitStr || '100', 10) || 100, 1), 500);
      if (this.db.isStub) {
        return { ok: true, mode: 'stub', sessions: [] } as any;
      }
      const data = await this.db.runInTx(async (q) => {
        let sinceFilter = '';
        let untilFilter = '';
        const argsSessions: any[] = [];
        if (since) {
          const d = new Date(since); if (!isNaN(d.getTime())) { sinceFilter = 'and m.created_at >= $1'; argsSessions.push(d.toISOString()); }
        }
        if (until) {
          const d = new Date(until); if (!isNaN(d.getTime())) { untilFilter = sinceFilter ? 'and m.created_at <= $2' : 'and m.created_at <= $1'; argsSessions.push(d.toISOString()); }
        }
        // Recent sessions ordered by latest message time
        const { rows: sessRows } = await q<{ id: string }>(
          `select s.id
             from chat_sessions s
             join messages m on m.session_id = s.id
            where (s.user_id = auth.uid() or s.vet_id = auth.uid())
              and m.deleted_at is null
              ${sinceFilter} ${untilFilter}
            group by s.id
            order by max(m.created_at) desc
            limit $${argsSessions.length + 1}`,
          [...argsSessions, sessionsLimit]
        );
        const sessionIds = sessRows.map(r => r.id);
        if (!sessionIds.length) return [] as any[];
        const { rows: msgRows } = await q<any>(
          `select m.id, m.session_id, m.sender_id, m.role, m.content, m.created_at
             from messages m
            where m.session_id = any($1::uuid[])
              and m.deleted_at is null
            order by m.session_id, m.created_at asc`,
          [sessionIds]
        );
        // Group and enforce perLimit
        const grouped: Record<string, any[]> = {};
        for (const m of msgRows) {
          const arr = grouped[m.session_id] || (grouped[m.session_id] = []);
          if (arr.length < perLimit) arr.push(m);
        }
        return Object.entries(grouped).map(([session_id, items]) => ({ session_id, items }));
      });
      return { ok: true, sessions: data, sessionsLimit, perLimit, since: since || null, until: until || null };
    } catch (e: any) {
      throw new HttpException(e?.message || 'transcripts_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Patch(':id/redact')
  async redact(@Param('id') id: string, @Body() body: { reason?: string }) {
    try {
      if (this.db.isStub) return { ok: true, id, redacted: true, mode: 'stub' };
      const reason = (body?.reason || '').slice(0, 500) || null;
      const row = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `update messages
              set redacted_at = now(),
                  redaction_reason = $2,
                  redacted_original_content = coalesce(redacted_original_content, content),
                  content = '[redacted]',
                  search_tsv = NULL
            where id = $1
              and deleted_at is null
            returning id, session_id, sender_id, role, content, redacted_at, redaction_reason`,
          [id, reason]
        );
        return rows[0];
      });
      if (!row) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
      return { ok: true, message: row };
    } catch (e: any) {
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'redact_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Delete(':id')
  async softDelete(@Param('id') id: string) {
    try {
      if (this.db.isStub) return { ok: true, id, deleted: true, mode: 'stub' };
      const row = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `update messages
              set deleted_at = now(),
                  redacted_original_content = coalesce(redacted_original_content, content),
                  content = '[deleted]',
                  search_tsv = NULL
            where id = $1
              and deleted_at is null
            returning id, session_id, sender_id, role, content, deleted_at`,
          [id]
        );
        return rows[0];
      });
      if (!row) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
      return { ok: true, message: row };
    } catch (e: any) {
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'delete_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Get(':id')
  async detail(@Param('id') id: string) {
    try {
      if (this.db.isStub) {
        return { id, role: 'user', content: '', created_at: new Date().toISOString(), stub: true } as any;
      }
      const row = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `select id, session_id, sender_id, role, content, created_at
             from messages
            where id = $1
            limit 1`,
          [id]
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
}
