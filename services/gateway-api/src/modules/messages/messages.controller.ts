import { Controller, Get, HttpException, HttpStatus, Param, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';

@Controller('messages')
@UseGuards(AuthGuard)
export class MessagesController {
  constructor(private readonly db: DbService) {}
  @Get()
  list() {
    return {
      ok: false,
      domain: 'messages',
      reason: 'not_ready',
      message: 'Messages API not ready; to be finished in frontend integration.',
      data: []
    };
  }

  @Get('transcripts')
  transcripts() {
    return {
      ok: false,
      domain: 'messages',
      reason: 'not_ready',
      message: 'Transcripts API not ready; to be finished in frontend integration.',
      data: []
    };
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
