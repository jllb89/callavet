import { Controller, Get, Param, Query, UseGuards, NotFoundException } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';

@UseGuards(AuthGuard)
@Controller()
export class EncountersController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

  @Get('pets/:petId/encounters')
  async listPetEncounters(@Param('petId') petId: string, @Query('limit') limitStr?: string) {
    const limit = Math.min(Math.max(Number(limitStr ?? '50'), 1), 200);
    const rows = await this.db.runInTx(async (q) => {
      const { rows } = await q(
        `select ce.id,
                ce.session_id,
                ce.appointment_id,
                ce.pet_id,
                ce.user_id,
                ce.vet_id,
                ce.video_room_id,
                ce.status,
                ce.started_at,
                ce.ended_at,
                ce.created_at,
                ce.updated_at,
                (select count(*)::int from consultation_notes n where n.encounter_id = ce.id) as notes_count,
                (select count(*)::int from image_cases i where i.encounter_id = ce.id) as image_cases_count,
                (select count(*)::int from care_plans cp where cp.encounter_id = ce.id) as care_plans_count
           from clinical_encounters ce
          where ce.pet_id = $1
            and (ce.user_id = $2 or ce.vet_id = $2 or is_admin())
          order by coalesce(ce.started_at, ce.created_at) desc
          limit $3`,
        [petId, this.rc.claims?.sub || null, limit]
      );
      return rows;
    });
    return { data: rows };
  }

  @Get('encounters/:encounterId')
  async getEncounter(@Param('encounterId') encounterId: string) {
    const payload = await this.db.runInTx(async (q) => {
      const { rows: encounters } = await q(
        `select id, session_id, appointment_id, pet_id, user_id, vet_id, video_room_id, status,
                started_at, ended_at, created_at, updated_at
           from clinical_encounters
          where id = $1
            and (user_id = $2 or vet_id = $2 or is_admin())
          limit 1`,
        [encounterId, this.rc.claims?.sub || null]
      );
      if (!encounters[0]) return null;

      const { rows: notes } = await q(
        `select id, encounter_id, session_id, vet_id, pet_id, summary_text, plan_summary, created_at
           from consultation_notes
          where encounter_id = $1
          order by created_at desc`,
        [encounterId]
      );

      const { rows: imageCases } = await q(
        `select id, encounter_id, pet_id, session_id, image_url, labels, findings, diagnosis_label, created_at
           from image_cases
          where encounter_id = $1
          order by created_at desc`,
        [encounterId]
      );

      const { rows: carePlans } = await q(
        `select id, encounter_id, pet_id, created_by_ai, short_term, mid_term, long_term, created_at
           from care_plans
          where encounter_id = $1
          order by created_at desc`,
        [encounterId]
      );

      return {
        encounter: encounters[0],
        notes,
        imageCases,
        carePlans,
      };
    });

    if (!payload) {
      throw new NotFoundException('encounter_not_found');
    }

    return payload;
  }
}