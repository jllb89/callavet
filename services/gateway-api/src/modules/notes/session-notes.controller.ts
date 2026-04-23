import { Body, Controller, Get, HttpException, HttpStatus, Param, Post, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';
import { EndpointRateLimitGuard } from '../rate-limit/endpoint-rate-limit.guard';
import { RateLimit } from '../rate-limit/rate-limit.decorator';

@UseGuards(AuthGuard)
@Controller('sessions')
export class SessionNotesController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

  @Get(':sessionId/notes')
  async listSessionNotes(@Param('sessionId') sessionId: string) {
    const items = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `select id, encounter_id, session_id, vet_id, pet_id,
                summary_text, plan_summary, assessment_text, diagnosis_text,
                follow_up_instructions, next_follow_up_at, severity, created_at
           from consultation_notes
          where session_id = $1
            and (
              -- Authoring vet can read their notes
              vet_id = $2
              -- Assigned session vet can read all notes for the session
              or exists (
                select 1 from chat_sessions s
                where s.id = consultation_notes.session_id and s.vet_id = $2
              )
              or exists (select 1 from pets p where p.id = consultation_notes.pet_id and p.user_id = $2)
              or is_admin()
            )
          order by created_at desc`,
        [sessionId, this.rc.claims?.sub || null]
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
  @UseGuards(EndpointRateLimitGuard)
  @RateLimit({ key: 'sessions.notes.create', limit: 10, windowMs: 300_000 })
  async createSessionNote(
    @Param('sessionId') sessionId: string,
    @Body()
    body: {
      summary_text?: string;
      plan_summary?: string;
      assessment_text?: string;
      diagnosis_text?: string;
      follow_up_instructions?: string;
      next_follow_up_at?: string;
      severity?: 'low' | 'medium' | 'high' | 'critical';
      pet_id?: string;
    }
  ) {
    const summaryText = (body?.summary_text || '').toString().trim();
    const planSummary = (body?.plan_summary || '').toString().trim();
    const assessmentText = (body?.assessment_text || '').toString().trim();
    const diagnosisText = (body?.diagnosis_text || '').toString().trim();
    const followUpInstructions = (body?.follow_up_instructions || '').toString().trim();
    const severity = body?.severity ? String(body.severity).trim().toLowerCase() : null;
    const nextFollowUpAt = body?.next_follow_up_at ? new Date(body.next_follow_up_at) : null;

    if (!summaryText && !planSummary && !assessmentText && !diagnosisText && !followUpInstructions) {
      throw new HttpException('structured_note_content_required', HttpStatus.BAD_REQUEST);
    }
    if (
      summaryText.length > 8000 ||
      planSummary.length > 8000 ||
      assessmentText.length > 8000 ||
      diagnosisText.length > 4000 ||
      followUpInstructions.length > 4000
    ) {
      throw new HttpException('note_too_long', HttpStatus.BAD_REQUEST);
    }
    if (severity && !['low', 'medium', 'high', 'critical'].includes(severity)) {
      throw new HttpException('severity_invalid', HttpStatus.BAD_REQUEST);
    }
    if (nextFollowUpAt && Number.isNaN(nextFollowUpAt.getTime())) {
      throw new HttpException('next_follow_up_at_invalid', HttpStatus.BAD_REQUEST);
    }
    let pet_id = (body || {}).pet_id || null;
    // Derive pet_id from session if not provided
    if (!pet_id) {
      const s = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `select pet_id from chat_sessions where id = $1 limit 1`,
          [sessionId]
        );
        return rows[0];
      });
      pet_id = (s as any)?.pet_id || null;
    }
    if (!pet_id) {
      return { ok: false, reason: 'pet_id_missing' } as any;
    }
    try {
      const row = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `insert into consultation_notes (
             id,
             encounter_id,
             session_id,
             vet_id,
             pet_id,
             summary_text,
             plan_summary,
             assessment_text,
             diagnosis_text,
             follow_up_instructions,
             next_follow_up_at,
             severity,
             embedding,
             created_at
           )
           values (
             gen_random_uuid(),
             public.ensure_clinical_encounter($1, $2),
             $1,
             (select id from vets where id = auth.uid()),
             $2,
             $3,
             $4,
             $5,
             $6,
             $7,
             $8::timestamptz,
             $9,
             NULL,
             now()
           )
           returning id, encounter_id, session_id, vet_id, pet_id,
                     summary_text, plan_summary, assessment_text, diagnosis_text,
                     follow_up_instructions, next_follow_up_at, severity, created_at`,
          [
            sessionId,
            pet_id,
            summaryText || null,
            planSummary || null,
            assessmentText || null,
            diagnosisText || null,
            followUpInstructions || null,
            nextFollowUpAt ? nextFollowUpAt.toISOString() : null,
            severity,
          ]
        );
        if (process.env.DEV_DB_DEBUG === '1') {
          // eslint-disable-next-line no-console
          console.log('[notes:create] uid=%s session=%s ok=%s pet_id=%s', this.rc.claims?.sub, sessionId, rows.length === 1, pet_id);
        }
        return rows[0];
      });
      return row;
    } catch (e: any) {
      const msg = e?.message || String(e);
      // eslint-disable-next-line no-console
      console.error('[notes:create:error]', { uid: this.rc.claims?.sub, sessionId, pet_id, msg });
      return { ok: false, reason: 'create_failed', error: msg } as any;
    }
  }
}
