import {
  BadRequestException,
  Body,
  Controller,
  ForbiddenException,
  Get,
  Headers,
  HttpException,
  HttpStatus,
  Param,
  Patch,
  Post,
  Put,
  Query,
  UseGuards,
} from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { ValidatorService } from '../config/validator.service';
import { EnumService } from '../config/enum.service';
import { LiveKitService } from '../video/livekit.service';

type AvailabilityRow = {
  weekday: number;
  start_time: string;
  end_time: string;
  timezone: string | null;
};

/**
 * Internal helpers that use injected services
 * (Replaced hardcoded regex constants and validation functions)
 */
function normalizeAvailabilityPayload(
  payload: any,
  validator: ValidatorService,
): AvailabilityRow[] {
  const rows = Array.isArray(payload) ? payload : Array.isArray(payload?.template) ? payload.template : null;
  if (!rows) throw new BadRequestException('template must be an array');
  const normalized = rows.map((entry: any, index: number) => {
    const weekday = Number(entry?.weekday);
    if (!Number.isInteger(weekday) || weekday < 0 || weekday > 6) {
      throw new BadRequestException(`template[${index}].weekday must be an integer between 0 and 6`);
    }
    const start_time = validator.validateTime(entry?.start_time ?? entry?.startTime, `template[${index}].start_time`);
    const end_time = validator.validateTime(entry?.end_time ?? entry?.endTime, `template[${index}].end_time`);
    if (start_time >= end_time) {
      throw new BadRequestException(`template[${index}] start_time must be before end_time`);
    }
    const timezone = entry?.timezone ? String(entry.timezone).trim() : null;
    return { weekday, start_time, end_time, timezone };
  });

  const grouped = new Map<number, AvailabilityRow[]>();
  for (const row of normalized) {
    const existing = grouped.get(row.weekday) || [];
    existing.push(row);
    grouped.set(row.weekday, existing);
  }
  for (const dayRows of grouped.values()) {
    dayRows.sort((left, right) => left.start_time.localeCompare(right.start_time));
    for (let index = 1; index < dayRows.length; index += 1) {
      if (dayRows[index - 1].end_time > dayRows[index].start_time) {
        throw new BadRequestException('availability windows must not overlap for the same weekday');
      }
    }
  }
  return normalized;
}

@Controller('vets')
@UseGuards(AuthGuard)
export class VetsController {
  constructor(
    private readonly db: DbService,
    private readonly rc: RequestContext,
    private readonly validator: ValidatorService,
    private readonly enumService: EnumService,
    private readonly livekit: LiveKitService,
  ) {}

  private activeConsultMaxAgeMinutes() {
    return this.positiveEnvInt('VET_ACTIVE_CONSULT_MAX_AGE_MINUTES', 120);
  }

  private activeConsultLeftGraceMinutes() {
    return this.positiveEnvInt('VET_ACTIVE_CONSULT_LEFT_GRACE_MINUTES', 5);
  }

  private activeConsultWaitingTimeoutMinutes() {
    return this.positiveEnvInt('VET_ACTIVE_CONSULT_WAITING_TIMEOUT_MINUTES', 20);
  }

  private positiveEnvInt(name: string, fallback: number) {
    const raw = Number.parseInt((process.env[name] || '').trim(), 10);
    return Number.isFinite(raw) && raw > 0 ? raw : fallback;
  }

  private async currentActor(): Promise<{ id: string; role: string }> {
    const actorId = this.rc.requireUuidUserId();
    const { rows } = await this.db.query<{ id: string; role: string }>(
      `select id, role
         from users
        where id = $1::uuid
        limit 1`,
      [actorId]
    );
    if (!rows[0]) throw new ForbiddenException('actor_not_found');
    return rows[0];
  }

  private async loadSpecialtyDetails(specialtyIds: string[]) {
    if (!specialtyIds.length) return [] as any[];
    const { rows } = await this.db.query<any>(
      `select id, name, description, coalesce(is_active, true) as is_active, sort_order
         from vet_specialties
        where id = any($1::uuid[])
        order by sort_order asc, lower(name) asc`,
      [specialtyIds]
    );
    return rows;
  }

  private async loadClinicAffiliations(vetId: string) {
    const { rows } = await this.db.query<any>(
      `select c.id,
              c.name,
              c.address,
              c.phone,
              c.website,
              c.is_partner,
              a.role
         from vet_clinic_affiliations a
         join vet_care_centers c on c.id = a.clinic_id
        where a.vet_id = $1::uuid
        order by lower(c.name) asc`,
      [vetId]
    );
    return rows;
  }

  private async loadAvailabilityTemplate(vetId: string) {
    const { rows } = await this.db.query<any>(
      `select weekday, start_time, end_time, timezone
         from vet_availability
        where vet_id = $1::uuid
        order by weekday asc, start_time asc`,
      [vetId]
    );
    return { template: rows, overrides: [] };
  }

  private async getVetBase(vetId: string, includePrivate = false) {
    const { rows } = await this.db.query<any>(
      `select v.id,
              u.full_name,
              ${includePrivate ? 'u.email, u.phone,' : ''}
              v.license_number,
              v.country,
              v.bio,
              v.years_experience,
              v.is_approved,
              coalesce(v.specialties, '{}'::uuid[]) as specialties,
              coalesce(v.languages, '{}'::text[]) as languages,
              coalesce(avg(r.score)::numeric(10,2), 0) as rating_average,
              count(r.id)::int as rating_count
         from vets v
         join users u on u.id = v.id
         left join ratings r on r.vet_id = v.id
        where v.id = $1::uuid
        group by v.id, u.full_name, ${includePrivate ? 'u.email, u.phone,' : ''} v.license_number, v.country, v.bio, v.years_experience, v.is_approved, v.specialties, v.languages`,
      [vetId]
    );
    return rows[0];
  }

  private async buildVetDetail(vetId: string, includePrivate = false) {
    const base = await this.getVetBase(vetId, includePrivate);
    if (!base) throw new BadRequestException('not_found');
    const specialties = await this.loadSpecialtyDetails(base.specialties || []);
    const clinics = await this.loadClinicAffiliations(vetId);
    return {
      ...base,
      specialty_details: specialties,
      clinics,
    };
  }

  private async getVetStatus(vetId: string) {
    const base = await this.getVetBase(vetId);
    if (!base) throw new BadRequestException('not_found');
    const maxAgeMinutes = this.activeConsultMaxAgeMinutes();
    const leftGraceMinutes = this.activeConsultLeftGraceMinutes();
    const waitingTimeoutMinutes = this.activeConsultWaitingTimeoutMinutes();
    const { rows } = await this.db.query<any>(
      `select
         (select count(*)::int
            from appointments a
           where a.vet_id = $1::uuid
             and a.status in ('scheduled', 'confirmed')
             and a.starts_at >= now()) as upcoming_appointments,
         (select count(*)::int
            from (
              select a.id
                from appointments a
                left join chat_sessions s on s.id = a.session_id
                left join video_session_lifecycle v on v.session_id = a.session_id
               where a.vet_id = $1::uuid
                 and a.status = 'active'
                 and a.starts_at >= now() - ($2::int * interval '1 minute')
                 and (
                   coalesce(s.mode, 'video') <> 'video'
                   or (
                     coalesce(v.status, 'pending') not in ('ended', 'released', 'timed_out', 'host_absent', 'forced_ended')
                     and v.room_finished_at is null
                     and v.forced_end_at is null
                     and (v.last_participant_left_at is null or v.last_participant_left_at >= now() - ($3::int * interval '1 minute'))
                     and (v.first_both_joined_at is not null or v.first_participant_joined_at is null or v.first_participant_joined_at >= now() - ($4::int * interval '1 minute'))
                   )
                 )
              union all
              select s.id
                from chat_sessions s
                left join video_session_lifecycle v on v.session_id = s.id
               where s.vet_id = $1::uuid
                 and s.status = 'active'
                 and coalesce(s.started_at, s.created_at) >= now() - ($2::int * interval '1 minute')
                 and (
                   coalesce(s.mode, 'chat') <> 'video'
                   or (
                     coalesce(v.status, 'pending') not in ('ended', 'released', 'timed_out', 'host_absent', 'forced_ended')
                     and v.room_finished_at is null
                     and v.forced_end_at is null
                     and (v.last_participant_left_at is null or v.last_participant_left_at >= now() - ($3::int * interval '1 minute'))
                     and (v.first_both_joined_at is not null or v.first_participant_joined_at is null or v.first_participant_joined_at >= now() - ($4::int * interval '1 minute'))
                   )
                 )
            ) active_rows) as active_consults,
         (select count(*)::int
            from chat_sessions s
            left join consultation_notes n on n.session_id = s.id
           where s.vet_id = $1::uuid
             and s.status = 'completed'
             and n.id is null) as pending_notes,
         (select count(*)::int
            from vet_referrals vr
            left join vets v on v.id = $1::uuid
           where (vr.assigned_vet_id = $1::uuid
               or (vr.assigned_vet_id is null and (vr.specialty_id is null or array_position(v.specialties, vr.specialty_id) is not null)))
             and vr.status in ('intake', 'assigned', 'accepted')) as open_referrals`,
      [vetId, maxAgeMinutes, leftGraceMinutes, waitingTimeoutMinutes]
    );
    return {
      id: base.id,
      is_approved: base.is_approved,
      rating_average: base.rating_average,
      rating_count: base.rating_count,
      ...rows[0],
    };
  }

  @Get('specialties')
  async listSpecialties() {
    if (this.db.isStub) return { data: [] } as any;
    const { rows } = await this.db.query(
      `select id, name, description, coalesce(is_active, true) as is_active, sort_order
         from vet_specialties
        order by coalesce(is_active, true) desc, sort_order asc, lower(name) asc`
    );
    return { data: rows };
  }

  @Get()
  async listVets(
    @Query('q') q?: string,
    @Query('specialtyId') specialtyId?: string,
    @Query('specialty_id') specialtyIdAlt?: string,
    @Query('includeUnapproved') includeUnapprovedRaw?: string,
    @Query('limit') limitRaw?: string,
    @Query('offset') offsetRaw?: string,
  ) {
    if (this.db.isStub) return { data: [] } as any;
    const actor = await this.currentActor();
    const includeUnapproved = /^(1|true)$/i.test(includeUnapprovedRaw || '');
    if (includeUnapproved && actor.role !== 'admin') {
      throw new ForbiddenException('includeUnapproved_requires_admin');
    }
    const limit = Math.min(Math.max(parseInt(limitRaw || '20', 10) || 20, 1), 100);
    const offset = Math.max(parseInt(offsetRaw || '0', 10) || 0, 0);
    const search = q?.trim() ? `%${q.trim().toLowerCase()}%` : null;
    const specialtyFilter = (specialtyId || specialtyIdAlt || '').trim() || null;
    if (specialtyFilter) this.validator.validateUUID(specialtyFilter, 'specialtyId');

    const { rows } = await this.db.query<any>(
      `select v.id,
              u.full_name,
              v.license_number,
              v.country,
              v.bio,
              v.years_experience,
              v.is_approved,
              coalesce(v.specialties, '{}'::uuid[]) as specialties,
              coalesce(v.languages, '{}'::text[]) as languages,
              coalesce(avg(r.score)::numeric(10,2), 0) as rating_average,
              count(r.id)::int as rating_count
         from vets v
         join users u on u.id = v.id
         left join ratings r on r.vet_id = v.id
        where ($1::text is null
               or lower(coalesce(u.full_name, '')) like $1
               or lower(coalesce(v.bio, '')) like $1
               or lower(coalesce(v.country, '')) like $1)
          and ($2::uuid is null or array_position(v.specialties, $2::uuid) is not null)
          and ($3::boolean = true or v.is_approved = true)
        group by v.id, u.full_name, v.license_number, v.country, v.bio, v.years_experience, v.is_approved, v.specialties, v.languages
        order by v.is_approved desc, count(r.id) desc, u.full_name asc
        limit $4 offset $5`,
      [search, specialtyFilter, includeUnapproved, limit, offset]
    );
    return { data: rows };
  }

  @Get('me/profile')
  async myProfile() {
    const actor = await this.currentActor();
    if (actor.role !== 'vet' && actor.role !== 'admin') throw new ForbiddenException('vet_role_required');
    return this.buildVetDetail(actor.id, true);
  }

  @Patch('me/profile')
  async updateMyProfile(
    @Body()
    body: {
      license_number?: string | null;
      country?: string | null;
      bio?: string | null;
      years_experience?: number | null;
      specialties?: string[];
      languages?: string[];
    }
  ) {
    const actor = await this.currentActor();
    if (actor.role !== 'vet') throw new ForbiddenException('vet_role_required');
    const payload = body || {};
    const hasLicenseNumber = Object.prototype.hasOwnProperty.call(payload, 'license_number');
    const hasCountry = Object.prototype.hasOwnProperty.call(payload, 'country');
    const hasBio = Object.prototype.hasOwnProperty.call(payload, 'bio');
    const hasYearsExperience = Object.prototype.hasOwnProperty.call(payload, 'years_experience');
    const hasSpecialties = Object.prototype.hasOwnProperty.call(payload, 'specialties');
    const hasLanguages = Object.prototype.hasOwnProperty.call(payload, 'languages');
    const specialties = this.validator.parseUuidArray(payload.specialties, 'specialties');
    const languages = this.validator.parseStringArray(payload.languages, 'languages');
    const yearsExperience = payload.years_experience == null ? null : Number(payload.years_experience);
    if (yearsExperience != null && (!Number.isInteger(yearsExperience) || yearsExperience < 0)) {
      throw new BadRequestException('years_experience must be a non-negative integer');
    }

    await this.db.runInTx(async (q) => {
      const { rows: userRows } = await q<{ role: string }>(
        `select role from users where id = $1::uuid limit 1`,
        [actor.id]
      );
      if (userRows[0]?.role !== 'vet') throw new ForbiddenException('vet_role_required');
      await q(
        `insert into vets (id, license_number, country, bio, years_experience, is_approved, specialties, languages, created_at, updated_at)
         values ($1::uuid, $2, $3, $4, $5, false, $6::uuid[], $7::text[], now(), now())
         on conflict (id) do update set
           license_number = case when $8::boolean then excluded.license_number else vets.license_number end,
           country = case when $9::boolean then excluded.country else vets.country end,
           bio = case when $10::boolean then excluded.bio else vets.bio end,
           years_experience = case when $11::boolean then excluded.years_experience else vets.years_experience end,
           specialties = case when $12::boolean then $6::uuid[] else vets.specialties end,
           languages = case when $13::boolean then $7::text[] else vets.languages end,
           updated_at = now()`,
        [
          actor.id,
          hasLicenseNumber ? String(payload.license_number || '').trim() || null : null,
          hasCountry ? String(payload.country || '').trim() || null : null,
          hasBio ? String(payload.bio || '').trim() || null : null,
          yearsExperience,
          specialties,
          languages,
          hasLicenseNumber,
          hasCountry,
          hasBio,
          hasYearsExperience,
          hasSpecialties,
          hasLanguages,
        ]
      );
    });

    return this.buildVetDetail(actor.id, true);
  }

  @Get('me/status')
  async myStatus() {
    const actor = await this.currentActor();
    if (actor.role !== 'vet' && actor.role !== 'admin') throw new ForbiddenException('vet_role_required');
    return this.getVetStatus(actor.id);
  }

  @Get('me/availability')
  async myAvailability() {
    const actor = await this.currentActor();
    if (actor.role !== 'vet' && actor.role !== 'admin') throw new ForbiddenException('vet_role_required');
    return this.loadAvailabilityTemplate(actor.id);
  }

  @Put('me/availability')
  async replaceMyAvailability(@Body() body: { template?: AvailabilityRow[] } | AvailabilityRow[]) {
    const actor = await this.currentActor();
    if (actor.role !== 'vet') throw new ForbiddenException('vet_role_required');
    const rows = normalizeAvailabilityPayload(body, this.validator);
    await this.db.runInTx(async (q) => {
      const { rows: vetRows } = await q<{ id: string }>(
        `select id from vets where id = $1::uuid limit 1`,
        [actor.id]
      );
      if (!vetRows[0]) throw new BadRequestException('vet_profile_not_found');
      await q(`delete from vet_availability where vet_id = $1::uuid`, [actor.id]);
      for (const row of rows) {
        await q(
          `insert into vet_availability (id, vet_id, weekday, start_time, end_time, timezone)
           values (gen_random_uuid(), $1::uuid, $2, $3::time, $4::time, $5)`,
          [actor.id, row.weekday, row.start_time, row.end_time, row.timezone]
        );
      }
    });
    return this.loadAvailabilityTemplate(actor.id);
  }

  @Get('me/queue')
  async myQueue() {
    const actor = await this.currentActor();
    if (actor.role !== 'vet' && actor.role !== 'admin') throw new ForbiddenException('vet_role_required');
    const vetId = actor.id;
    const maxAgeMinutes = this.activeConsultMaxAgeMinutes();
    const leftGraceMinutes = this.activeConsultLeftGraceMinutes();
    const waitingTimeoutMinutes = this.activeConsultWaitingTimeoutMinutes();
    const [upcomingAppointments, activeConsults, pendingNotes, referrals] = await Promise.all([
      this.db.query<any>(
        `select a.id,
                a.session_id,
                a.user_id,
                u.full_name as user_name,
                a.starts_at,
                a.ends_at,
                a.status,
                coalesce(s.mode, 'video') as mode
           from appointments a
           join users u on u.id = a.user_id
      left join chat_sessions s on s.id = a.session_id
          where a.vet_id = $1::uuid
            and a.status in ('scheduled', 'confirmed')
            and a.starts_at >= now()
          order by a.starts_at asc
          limit 20`,
        [vetId]
      ),
      this.db.query<any>(
        `select 'appointment' as source,
                a.id,
                a.session_id,
                a.user_id,
                u.full_name as user_name,
                a.starts_at as started_at,
                a.ends_at,
                a.status,
                 coalesce(s.mode, 'video') as mode,
                 s.specialty_id,
                 vs.name as specialty_name,
                 s.priority,
                v.status as lifecycle_status
           from appointments a
           join users u on u.id = a.user_id
      left join chat_sessions s on s.id = a.session_id
             left join vet_specialties vs on vs.id = s.specialty_id
      left join video_session_lifecycle v on v.session_id = a.session_id
          where a.vet_id = $1::uuid
            and a.status = 'active'
            and a.starts_at >= now() - ($2::int * interval '1 minute')
            and (
              coalesce(s.mode, 'video') <> 'video'
              or (
                coalesce(v.status, 'pending') not in ('ended', 'released', 'timed_out', 'host_absent', 'forced_ended')
                and v.room_finished_at is null
                and v.forced_end_at is null
                and (v.last_participant_left_at is null or v.last_participant_left_at >= now() - ($3::int * interval '1 minute'))
                and (v.first_both_joined_at is not null or v.first_participant_joined_at is null or v.first_participant_joined_at >= now() - ($4::int * interval '1 minute'))
              )
            )
         union all
         select 'session' as source,
                s.id,
                s.id as session_id,
                s.user_id,
                u.full_name as user_name,
                s.started_at,
                s.ended_at,
                s.status,
                s.mode,
                 s.specialty_id,
                 vs.name as specialty_name,
                 s.priority,
                case
                  when coalesce(s.mode, 'chat') = 'chat'
                   and s.status = 'completed'
                   and s.ended_at >= now() - interval '5 minutes'
                  then 'rejoin_grace'
                  else v.status
                end as lifecycle_status
           from chat_sessions s
           join users u on u.id = s.user_id
             left join vet_specialties vs on vs.id = s.specialty_id
      left join video_session_lifecycle v on v.session_id = s.id
          where s.vet_id = $1::uuid
            and (
              s.status = 'active'
              or (
                coalesce(s.mode, 'chat') = 'chat'
                and s.status = 'completed'
                and s.ended_at >= now() - interval '5 minutes'
              )
            )
            and coalesce(s.started_at, s.created_at) >= now() - ($2::int * interval '1 minute')
            and (
              coalesce(s.mode, 'chat') <> 'video'
              or (
                coalesce(v.status, 'pending') not in ('ended', 'released', 'timed_out', 'host_absent', 'forced_ended')
                and v.room_finished_at is null
                and v.forced_end_at is null
                and (v.last_participant_left_at is null or v.last_participant_left_at >= now() - ($3::int * interval '1 minute'))
                and (v.first_both_joined_at is not null or v.first_participant_joined_at is null or v.first_participant_joined_at >= now() - ($4::int * interval '1 minute'))
              )
            )
          order by started_at desc
          limit 20`,
        [vetId, maxAgeMinutes, leftGraceMinutes, waitingTimeoutMinutes]
      ),
      this.db.query<any>(
        `select s.id as session_id,
                s.user_id,
                u.full_name as user_name,
                s.pet_id,
                p.name as pet_name,
                s.ended_at
           from chat_sessions s
           join users u on u.id = s.user_id
           left join pets p on p.id = s.pet_id
           left join consultation_notes n on n.session_id = s.id
          where s.vet_id = $1::uuid
            and s.status = 'completed'
            and n.id is null
          order by s.ended_at desc nulls last
          limit 20`,
        [vetId]
      ),
      this.db.query<any>(
        `select vr.id,
                vr.pet_id,
                p.name as pet_name,
                vr.user_id,
                u.full_name as user_name,
                vr.specialty_id,
                vs.name as specialty_name,
                vr.assigned_vet_id,
                vr.appointment_id,
                vr.priority,
                vr.status,
                vr.notes,
                vr.created_at,
                vr.updated_at
           from vet_referrals vr
           join users u on u.id = vr.user_id
           left join pets p on p.id = vr.pet_id
           left join vet_specialties vs on vs.id = vr.specialty_id
           left join vets v on v.id = $1::uuid
          where vr.assigned_vet_id = $1::uuid
             or (vr.assigned_vet_id is null and (vr.specialty_id is null or array_position(v.specialties, vr.specialty_id) is not null))
          order by vr.created_at desc
          limit 20`,
        [vetId]
      ),
    ]);
    return {
      upcomingAppointments: upcomingAppointments.rows,
      activeConsults: activeConsults.rows,
      pendingNotes: pendingNotes.rows,
      referrals: referrals.rows,
    };
  }

  @Post('me/consults/:sessionId/end')
  async endActiveConsult(@Param('sessionId') sessionId: string) {
    const actor = await this.currentActor();
    if (actor.role !== 'vet' && actor.role !== 'admin') throw new ForbiddenException('vet_role_required');
    const normalizedSessionId = String(sessionId || '').trim();
    this.validator.validateUUID(normalizedSessionId, 'sessionId');
    console.log(JSON.stringify({
      scope: 'video_handoff_roadmap',
      component: 'vets',
      event: 'manual_consult_end.requested',
      at: new Date().toISOString(),
      sessionId: normalizedSessionId,
      actorId: actor.id,
      actorRole: actor.role,
    }));

    if (this.db.isStub) return { ok: true, sessionId: normalizedSessionId, ended: true, mode: 'stub' };

    const { rows: sessionRows } = await this.db.query<any>(
      `select id, vet_id, status, mode
         from chat_sessions
        where id = $1::uuid
          and ($2 = 'admin' or vet_id = $3::uuid)
        limit 1`,
      [normalizedSessionId, actor.role, actor.id]
    );
    const session = sessionRows[0];
    if (!session) throw new HttpException('not_found', HttpStatus.NOT_FOUND);

    const isVideo = String(session.mode || '').toLowerCase() === 'video';
    const roomName = isVideo ? this.livekit.roomNameForSession(normalizedSessionId) : null;
    let providerResult: any = null;
    let providerError: string | null = null;

    if (roomName) {
      try {
        providerResult = await this.livekit.endRoom(roomName);
      } catch (err: any) {
        providerError = err?.message || 'livekit_end_failed';
      }
    }

    const settlement = await this.db.runInTx(async (q) => {
      const { rows: lockedRows } = await q<any>(
        `select id, status, mode
           from chat_sessions
          where id = $1::uuid
            and ($2 = 'admin' or vet_id = $3::uuid)
          for update`,
        [normalizedSessionId, actor.role, actor.id]
      );
      const locked = lockedRows[0];
      if (!locked) return null;
      const alreadyClosed = ['completed', 'canceled', 'no_show'].includes(String(locked.status || '').toLowerCase());
      const lockedIsVideo = String(locked.mode || '').toLowerCase() === 'video';
      let engaged = !lockedIsVideo;
      let entitlementAction = 'none';
      let consumptionId: string | null = null;

      if (lockedIsVideo) {
        const resolvedRoomName = roomName || this.livekit.roomNameForSession(normalizedSessionId);
        await q(
          `insert into video_session_lifecycle (session_id, room_name, status, forced_end_at, safety_reason, created_at, updated_at)
           values ($1::uuid, $2, 'forced_ended', now(), 'manual_vet_end', now(), now())
           on conflict (session_id) do update
             set room_name = coalesce(video_session_lifecycle.room_name, excluded.room_name),
                 forced_end_at = coalesce(video_session_lifecycle.forced_end_at, now()),
                 safety_reason = 'manual_vet_end',
                 end_reason = case when $3 then 'admin_ended' else 'vet_ended' end,
                 end_actor_role = case when $3 then 'admin' else 'vet' end,
                 end_actor_user_id = $4::uuid,
                 rejoin_eligible_until = coalesce(video_session_lifecycle.rejoin_eligible_until, now() + interval '10 minutes'),
                 updated_at = now()`,
          [normalizedSessionId, resolvedRoomName, actor.role === 'admin', actor.id]
        );

        const { rows: stateRows } = await q<any>(
          `select v.first_both_joined_at::text,
                  v.entitlement_finalized_at::text,
                  ec.id as consumption_id,
                  ec.finalized as consumption_finalized
             from video_session_lifecycle v
        left join lateral (
              select id, finalized
                from entitlement_consumptions
               where session_id = v.session_id
                 and consumption_type = 'video'
                 and canceled_at is null
               order by created_at desc
               limit 1
             ) ec on true
            where v.session_id = $1::uuid
            limit 1`,
          [normalizedSessionId]
        );
        const state = stateRows[0];
        consumptionId = state?.consumption_id || null;
        engaged = !!state?.first_both_joined_at || state?.consumption_finalized === true || !!state?.entitlement_finalized_at;

        if (consumptionId && engaged && state?.consumption_finalized !== true) {
          const { rows } = await q<any>(`select fn_commit_consumption($1::uuid) as ok`, [consumptionId]);
          if (rows[0]?.ok) entitlementAction = 'committed';
        } else if (consumptionId && !engaged) {
          const { rows } = await q<any>(`select fn_release_consumption($1::uuid) as ok`, [consumptionId]);
          if (rows[0]?.ok) entitlementAction = 'released';
        }

        await q(
          `update video_session_lifecycle
              set status = $2,
                  room_finished_at = coalesce(room_finished_at, now()),
                  entitlement_consumption_id = coalesce(entitlement_consumption_id, $3::uuid),
                  entitlement_finalized_at = case when $4 then coalesce(entitlement_finalized_at, now()) else entitlement_finalized_at end,
                  entitlement_released_at = case when $5 then coalesce(entitlement_released_at, now()) else entitlement_released_at end,
                  safety_reason = 'manual_vet_end',
                  end_reason = case when $6 then 'admin_ended' else 'vet_ended' end,
                  end_actor_role = case when $6 then 'admin' else 'vet' end,
                  end_actor_user_id = $7::uuid,
                  rejoin_eligible_until = coalesce(rejoin_eligible_until, now() + interval '10 minutes'),
                  updated_at = now()
            where session_id = $1::uuid`,
          [normalizedSessionId, engaged ? 'ended' : 'forced_ended', consumptionId, entitlementAction === 'committed', entitlementAction === 'released', actor.role === 'admin', actor.id]
        );
      }

      const finalSessionStatus = engaged ? 'completed' : 'canceled';
      await q(
        `update chat_sessions
            set status = $2,
                ended_at = coalesce(ended_at, now()),
                updated_at = now()
          where id = $1::uuid`,
        [normalizedSessionId, finalSessionStatus]
      );
        await q(`select fn_release_vet_consult_lock($1::uuid, $2)`, [normalizedSessionId, 'manual_vet_end']);
      await q(
        `update appointments
            set status = case when $2 then 'completed' else case when status = 'completed' then status else 'no_show' end end
          where session_id = $1::uuid`,
        [normalizedSessionId, engaged]
      );
      await q(
        `update clinical_encounters
            set status = 'closed',
                ended_at = coalesce(ended_at, now()),
                updated_at = now()
          where session_id = $1::uuid`,
        [normalizedSessionId]
      );

      return {
        alreadyClosed,
        status: finalSessionStatus,
        mode: locked.mode,
        engaged,
        entitlementAction,
        consumptionId,
      };
    });

    if (!settlement) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
    console.log(JSON.stringify({
      scope: 'video_handoff_roadmap',
      component: 'vets',
      event: 'manual_consult_end.completed',
      at: new Date().toISOString(),
      sessionId: normalizedSessionId,
      actorId: actor.id,
      actorRole: actor.role,
      mode: settlement.mode,
      status: settlement.status,
      engaged: settlement.engaged,
      entitlementAction: settlement.entitlementAction,
      providerError,
    }));
    if (String(settlement.mode || '').toLowerCase() !== 'video') {
      console.log(JSON.stringify({
        scope: 'chat_consultation_realtime',
        component: 'vets',
        event: 'consult_end.completed',
        at: new Date().toISOString(),
        sessionId: normalizedSessionId,
        actorId: actor.id,
        actorRole: actor.role,
        status: settlement.status,
        engaged: settlement.engaged,
        entitlementAction: settlement.entitlementAction,
      }));
    }
    return {
      ok: true,
      sessionId: normalizedSessionId,
      ended: true,
      provider: roomName ? { roomName, result: providerResult, error: providerError } : null,
      settlement,
    };
  }

  @Get('referrals')
  async listReferrals(@Query('status') status?: string) {
    const actor = await this.currentActor();
    const normalizedStatus = status ? String(status).trim().toLowerCase() : null;
    if (normalizedStatus && !['intake', 'assigned', 'accepted', 'completed', 'canceled'].includes(normalizedStatus)) {
      throw new BadRequestException('invalid referral status');
    }

    if (this.db.isStub) return { data: [] } as any;

    if (actor.role === 'admin') {
      const { rows } = await this.db.query<any>(
        `select vr.id,
                vr.pet_id,
                p.name as pet_name,
                vr.user_id,
                u.full_name as user_name,
                vr.specialty_id,
                vs.name as specialty_name,
                vr.assigned_vet_id,
                vet_user.full_name as assigned_vet_name,
                vr.appointment_id,
                vr.priority,
                vr.status,
                vr.notes,
                vr.created_at,
                vr.updated_at
           from vet_referrals vr
           join users u on u.id = vr.user_id
           left join pets p on p.id = vr.pet_id
           left join vet_specialties vs on vs.id = vr.specialty_id
           left join users vet_user on vet_user.id = vr.assigned_vet_id
          where ($1::text is null or vr.status = $1)
          order by vr.created_at desc`,
        [normalizedStatus]
      );
      return { data: rows };
    }

    if (actor.role === 'vet') {
      const { rows } = await this.db.query<any>(
        `select vr.id,
                vr.pet_id,
                p.name as pet_name,
                vr.user_id,
                u.full_name as user_name,
                vr.specialty_id,
                vs.name as specialty_name,
                vr.assigned_vet_id,
                vr.appointment_id,
                vr.priority,
                vr.status,
                vr.notes,
                vr.created_at,
                vr.updated_at
           from vet_referrals vr
           join users u on u.id = vr.user_id
           left join pets p on p.id = vr.pet_id
           left join vet_specialties vs on vs.id = vr.specialty_id
           left join vets v on v.id = $1::uuid
          where (vr.assigned_vet_id = $1::uuid
              or (vr.assigned_vet_id is null and (vr.specialty_id is null or array_position(v.specialties, vr.specialty_id) is not null)))
            and ($2::text is null or vr.status = $2)
          order by vr.created_at desc`,
        [actor.id, normalizedStatus]
      );
      return { data: rows };
    }

    const { rows } = await this.db.query<any>(
      `select vr.id,
              vr.pet_id,
              p.name as pet_name,
              vr.user_id,
              vr.specialty_id,
              vs.name as specialty_name,
              vr.assigned_vet_id,
              vr.appointment_id,
              vr.priority,
              vr.status,
              vr.notes,
              vr.created_at,
              vr.updated_at
         from vet_referrals vr
         left join pets p on p.id = vr.pet_id
         left join vet_specialties vs on vs.id = vr.specialty_id
        where vr.user_id = $1::uuid
          and ($2::text is null or vr.status = $2)
        order by vr.created_at desc`,
      [actor.id, normalizedStatus]
    );
    return { data: rows };
  }

  @Post('referrals')
  async createReferral(
    @Body()
    body: {
      petId?: string;
      specialtyId?: string;
      assignedVetId?: string;
      notes?: string;
      priority?: 'routine' | 'urgent';
    }
  ) {
    const actor = await this.currentActor();
    if (actor.role === 'vet') throw new ForbiddenException('owners_or_admin_only');
    const petId = String(body?.petId || '').trim();
    if (!petId) throw new BadRequestException('petId required');
    this.validator.validateUUID(petId, 'petId');
    const specialtyId = body?.specialtyId ? String(body.specialtyId).trim() : null;
    if (specialtyId) this.validator.validateUUID(specialtyId, 'specialtyId');
    const assignedVetId = body?.assignedVetId ? String(body.assignedVetId).trim() : null;
    if (assignedVetId) this.validator.validateUUID(assignedVetId, 'assignedVetId');
    const notes = typeof body?.notes === 'string' ? body.notes.trim() : null;
    const priorityVal = String(body?.priority || 'routine').trim().toLowerCase();
    const allPriorities = this.enumService.getValues('vet_referrals', 'priority');
    const priority = allPriorities.has(priorityVal) ? priorityVal : 'routine';

    const row = await this.db.runInTx(async (q) => {
      if (actor.role !== 'admin') {
        const { rows: petRows } = await q<{ id: string }>(
          `select id from pets where id = $1::uuid and user_id = $2::uuid limit 1`,
          [petId, actor.id]
        );
        if (!petRows[0]) throw new BadRequestException('pet_not_found_for_user');
      }

      if (assignedVetId) {
        const { rows: vetRows } = await q<{ id: string; specialties: string[]; is_approved: boolean }>(
          `select id, coalesce(specialties, '{}'::uuid[]) as specialties, is_approved
             from vets
            where id = $1::uuid
            limit 1`,
          [assignedVetId]
        );
        const vet = vetRows[0];
        if (!vet) throw new BadRequestException('assigned_vet_not_found');
        if (!vet.is_approved) throw new BadRequestException('assigned_vet_not_approved');
        if (specialtyId && !(vet.specialties || []).includes(specialtyId)) {
          throw new BadRequestException('assigned_vet_missing_specialty');
        }
      }

      const { rows } = await q<any>(
        `insert into vet_referrals (id, pet_id, user_id, specialty_id, assigned_vet_id, priority, status, notes, created_at, updated_at)
         values (
           gen_random_uuid(),
           $1::uuid,
           $2::uuid,
           $3::uuid,
           $4::uuid,
           $5,
           case when $4::uuid is null then 'intake' else 'assigned' end,
           $6,
           now(),
           now()
         )
         returning id, pet_id, user_id, specialty_id, assigned_vet_id, appointment_id, priority, status, notes, created_at, updated_at`,
        [petId, actor.id, specialtyId, assignedVetId, priority, notes]
      );
      return rows[0];
    });

    return row;
  }

  @Patch('referrals/:referralId')
  async patchReferral(
    @Param('referralId') referralId: string,
    @Body()
    body: {
      assignedVetId?: string;
      appointmentId?: string;
      status?: 'intake' | 'assigned' | 'accepted' | 'completed' | 'canceled';
      notes?: string;
    }
  ) {
    this.validator.validateUUID(referralId, 'referralId');
    const actor = await this.currentActor();
    const assignedVetId = body?.assignedVetId ? String(body.assignedVetId).trim() : null;
    if (assignedVetId) this.validator.validateUUID(assignedVetId, 'assignedVetId');
    const appointmentId = body?.appointmentId ? String(body.appointmentId).trim() : null;
    if (appointmentId) this.validator.validateUUID(appointmentId, 'appointmentId');
    const requestedStatus = body?.status ? String(body.status).trim().toLowerCase() : null;
    if (requestedStatus && !['intake', 'assigned', 'accepted', 'completed', 'canceled'].includes(requestedStatus)) {
      throw new BadRequestException('invalid referral status');
    }
    const notes = typeof body?.notes === 'string' ? body.notes.trim() : null;

    const row = await this.db.runInTx(async (q) => {
      const { rows: referralRows } = await q<any>(
        `select vr.*, coalesce(v.specialties, '{}'::uuid[]) as assigned_vet_specialties
           from vet_referrals vr
           left join vets v on v.id = coalesce(vr.assigned_vet_id, $2::uuid)
          where vr.id = $1::uuid
          limit 1`,
        [referralId, actor.id]
      );
      const referral = referralRows[0];
      if (!referral) throw new BadRequestException('not_found');

      const actorOwnsReferral = referral.user_id === actor.id;
      const actorAssignedVet = referral.assigned_vet_id === actor.id;
      const isAdmin = actor.role === 'admin';

      let nextAssignedVetId = assignedVetId ?? referral.assigned_vet_id ?? null;
      let nextStatus = requestedStatus ?? referral.status;

      if (actor.role === 'user' && !isAdmin) {
        if (!actorOwnsReferral) throw new ForbiddenException('referral_forbidden');
        if (requestedStatus && requestedStatus !== 'canceled') {
          throw new ForbiddenException('owners_can_only_cancel_referrals');
        }
        if (assignedVetId || appointmentId) throw new ForbiddenException('owners_cannot_assign_referrals');
      }

      if (actor.role === 'vet' && !isAdmin) {
        const { rows: vetRows } = await q<{ specialties: string[] }>(
          `select coalesce(specialties, '{}'::uuid[]) as specialties
             from vets
            where id = $1::uuid
            limit 1`,
          [actor.id]
        );
        const actorSpecialties = vetRows[0]?.specialties || [];
        const canSelfAssign = !referral.assigned_vet_id && (!referral.specialty_id || actorSpecialties.includes(referral.specialty_id));
        if (assignedVetId && assignedVetId !== actor.id) {
          throw new ForbiddenException('vets_can_only_assign_themselves');
        }
        if (!actorAssignedVet && !canSelfAssign) {
          throw new ForbiddenException('referral_forbidden');
        }
        if (assignedVetId === actor.id && !referral.assigned_vet_id) {
          nextAssignedVetId = actor.id;
          if (!requestedStatus) nextStatus = 'assigned';
        }
        if (requestedStatus === 'assigned' && nextAssignedVetId !== actor.id) {
          throw new ForbiddenException('assigned_status_requires_actor_assignment');
        }
      }

      const allowedTransitions: Record<string, string[]> = {
        intake: ['assigned', 'canceled'],
        assigned: ['accepted', 'canceled'],
        accepted: ['completed', 'canceled'],
        completed: [],
        canceled: [],
      };

      if (nextStatus !== referral.status) {
        if (!(allowedTransitions[referral.status] || []).includes(nextStatus)) {
          throw new BadRequestException('invalid_referral_transition');
        }
      }

      if (nextAssignedVetId) {
        const { rows: vetRows } = await q<{ id: string; specialties: string[]; is_approved: boolean }>(
          `select id, coalesce(specialties, '{}'::uuid[]) as specialties, is_approved
             from vets
            where id = $1::uuid
            limit 1`,
          [nextAssignedVetId]
        );
        const vet = vetRows[0];
        if (!vet) throw new BadRequestException('assigned_vet_not_found');
        if (!vet.is_approved) throw new BadRequestException('assigned_vet_not_approved');
        if (referral.specialty_id && !(vet.specialties || []).includes(referral.specialty_id)) {
          throw new BadRequestException('assigned_vet_missing_specialty');
        }
      }

      if (appointmentId) {
        const { rows: appointmentRows } = await q<{ id: string; vet_id: string }>(
          `select id, vet_id from appointments where id = $1::uuid limit 1`,
          [appointmentId]
        );
        if (!appointmentRows[0]) throw new BadRequestException('appointment_not_found');
        if (nextAssignedVetId && appointmentRows[0].vet_id !== nextAssignedVetId) {
          throw new BadRequestException('appointment_vet_mismatch');
        }
      }

      const { rows } = await q<any>(
        `update vet_referrals
            set assigned_vet_id = $2::uuid,
                appointment_id = coalesce($3::uuid, appointment_id),
                status = $4,
                notes = coalesce($5, notes),
                updated_at = now()
          where id = $1::uuid
          returning id, pet_id, user_id, specialty_id, assigned_vet_id, appointment_id, priority, status, notes, created_at, updated_at`,
        [referralId, nextAssignedVetId, appointmentId, nextStatus, notes]
      );
      return rows[0];
    });

    return row;
  }

  @Post(':vetId/approve')
  async approveVet(@Headers('x-admin-secret') secret: string, @Param('vetId') vetId: string) {
    this.validator.assertAdminSecret(secret);
    this.validator.validateUUID(vetId, 'vetId');
    await this.db.query(
      `update users
          set role = 'vet',
              updated_at = now()
        where id = $1::uuid`,
      [vetId]
    );
    const { rows } = await this.db.query<any>(
      `update vets
          set is_approved = true,
              updated_at = now()
        where id = $1::uuid
        returning id`,
      [vetId]
    );
    if (!rows[0]) throw new BadRequestException('not_found');
    return this.buildVetDetail(vetId);
  }

  @Get(':vetId/status')
  async status(@Param('vetId') vetId: string) {
    this.validator.validateUUID(vetId, 'vetId');
    return this.getVetStatus(vetId);
  }

  @Get(':vetId/availability')
  async availability(@Param('vetId') vetId: string) {
    this.validator.validateUUID(vetId, 'vetId');
    return this.loadAvailabilityTemplate(vetId);
  }

  @Get(':vetId')
  async detail(@Param('vetId') vetId: string) {
    this.validator.validateUUID(vetId, 'vetId');
    return this.buildVetDetail(vetId);
  }
}