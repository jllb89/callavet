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
                (select count(*)::int from care_plans cp where cp.encounter_id = ce.id) as care_plans_count,
                (select count(*)::int from encounter_files ef where ef.encounter_id = ce.id) as files_count
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
        `select id, encounter_id, session_id, vet_id, pet_id,
                summary_text, plan_summary, assessment_text, diagnosis_text,
                follow_up_instructions, next_follow_up_at, severity, created_at
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

      const { rows: files } = await q(
        `select id, encounter_id, pet_id, session_id, storage_path, content_type, labels, created_at
           from encounter_files
          where encounter_id = $1
          order by created_at desc`,
        [encounterId]
      );

      const { rows: appointments } = await q(
        `select a.id, a.session_id, a.vet_id, a.user_id, a.starts_at, a.ends_at, a.status
           from appointments a
          where a.id = $1`,
        [encounters[0].appointment_id]
      );

      const { rows: sessions } = await q(
        `select s.id, s.user_id, s.vet_id, s.pet_id, s.status, s.started_at, s.ended_at
           from chat_sessions s
          where s.id = $1`,
        [encounters[0].session_id]
      );

      const { rows: healthProfile } = await q(
        `select pet_id, allergies, chronic_conditions, current_medications, vaccine_history,
                injury_history, procedure_history, feed_profile, insurance, emergency_contacts,
                created_at, updated_at
           from pet_health_profiles
          where pet_id = $1
          limit 1`,
        [encounters[0].pet_id]
      );

      return {
        encounter: encounters[0],
        notes,
        imageCases,
        carePlans,
        files,
        appointment: appointments[0] || null,
        session: sessions[0] || null,
        healthProfile: healthProfile[0] || null,
      };
    });

    if (!payload) {
      throw new NotFoundException('encounter_not_found');
    }

    return payload;
  }
}