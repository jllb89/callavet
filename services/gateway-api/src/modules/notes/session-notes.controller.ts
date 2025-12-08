import { Body, Controller, Get, Param, Post, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';

@UseGuards(AuthGuard)
@Controller('sessions')
export class SessionNotesController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

  @Get(':sessionId/notes')
  async listSessionNotes(@Param('sessionId') sessionId: string) {
    const items = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `select id, session_id, vet_id, pet_id, summary_text, plan_summary, created_at
           from consultation_notes
          where session_id = $1
            and (
              vet_id = auth.uid()
              or exists (select 1 from pets p where p.id = consultation_notes.pet_id and p.user_id = auth.uid())
              or is_admin()
            )
          order by created_at desc`,
        [sessionId]
      );
      if (process.env.DEV_DB_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.log('[notes:list] uid=%s session=%s rows=%d', this.rc.claims?.sub, sessionId, rows.length);
      }
      return rows;
    });
    return { data: items };
  }

  @Post(':sessionId/notes')
  async createSessionNote(
    @Param('sessionId') sessionId: string,
    @Body() body: { summary_text?: string; plan_summary?: string; pet_id?: string }
  ) {
    const { summary_text, plan_summary, pet_id } = body || {};
    const row = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `insert into consultation_notes (id, session_id, vet_id, pet_id, summary_text, plan_summary, embedding, created_at)
         values (
           gen_random_uuid(),
           $1,
           (select id from vets where id = auth.uid()),
           $2,
           $3,
           $4,
           NULL,
           now()
         )
         returning id, session_id, vet_id, pet_id, summary_text, plan_summary, created_at`,
        [sessionId, pet_id || null, summary_text || null, plan_summary || null]
      );
      if (process.env.DEV_DB_DEBUG === '1') {
        // eslint-disable-next-line no-console
        console.log('[notes:create] uid=%s session=%s ok=%s', this.rc.claims?.sub, sessionId, rows.length === 1);
      }
      return rows[0];
    });
    return row;
  }
}
