import { BadRequestException, ConflictException, Injectable } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { RequestContext } from '../auth/request-context.service';
import { ValidatorService } from '../config/validator.service';

type TxQuery = <R = any>(sql: string, args?: any[]) => Promise<{ rows: R[] }>;

export type AppointmentCreateInput = {
  vetId?: string;
  vet_id?: string;
  petId?: string | null;
  pet_id?: string | null;
  startsAt?: string;
  starts_at?: string;
  durationMin?: number | null;
  duration_min?: number | null;
  specialtyId?: string;
  specialty_id?: string;
  priority?: string | null;
  mode?: string | null;
};

@Injectable()
export class AppointmentSchedulingService {
  constructor(
    private readonly db: DbService,
    private readonly rc: RequestContext,
    private readonly validator: ValidatorService,
  ) {}

  async listForActor(limit: number, offset: number) {
    if (this.db.isStub) return [];
    return this.db.runInTx(async (q) => this.listRows(q, limit, offset));
  }

  async availableSlots(args: {
    vetId: string;
    since?: string | null;
    until?: string | null;
    durationMin?: number | null;
    limit?: number;
  }) {
    if (this.db.isStub) return [];
    const vetId = this.normalizeRequiredUuid(args.vetId, 'vetId');
    const durationMin = this.normalizeDuration(args.durationMin);
    const since = args.since ? new Date(String(args.since)) : new Date();
    const until = args.until
      ? new Date(String(args.until))
      : new Date(since.getTime() + 7 * 24 * 60 * 60 * 1000);
    if (Number.isNaN(since.getTime()) || Number.isNaN(until.getTime()) || until <= since) {
      throw new BadRequestException('slot_window_invalid');
    }
    const { rows } = await this.db.query<any>(this.slotsSql(args.limit || 200), [
      vetId,
      since.toISOString(),
      until.toISOString(),
      durationMin,
    ]);
    return rows.map((row) => ({ start: row.slot_start, end: row.slot_end }));
  }

  async createScheduledVideo(input: AppointmentCreateInput) {
    return this.createScheduledConsult({ ...input, mode: 'video' });
  }

  async createScheduledConsult(input: AppointmentCreateInput) {
    const normalized = this.normalizeCreateInput(input);
    if (this.db.isStub) {
      const id = `appt_${Date.now()}`;
      const sessionId = `sess_${Date.now()}`;
      return this.shapeRow({
        id,
        session_id: sessionId,
        user_id: (this.rc.claims as any)?.sub || 'user_stub',
        vet_id: normalized.vetId,
        pet_id: normalized.petId,
        specialty_id: normalized.specialtyId,
        status: 'scheduled',
        mode: normalized.mode,
        starts_at: normalized.startsAt,
        ends_at: new Date(new Date(normalized.startsAt).getTime() + normalized.durationMin * 60 * 1000).toISOString(),
      });
    }

    return this.db.runInTx(async (q) => {
      await this.validateVetAndSpecialty(q, normalized.vetId, normalized.specialtyId);
      if (normalized.petId) await this.validatePetForUser(q, normalized.petId);
      const endsAt = new Date(new Date(normalized.startsAt).getTime() + normalized.durationMin * 60 * 1000).toISOString();
      await this.assertSlotAvailable(q, normalized.vetId, normalized.startsAt, endsAt);

      const { rows: sessionRows } = await q<{ id: string }>(
        `insert into chat_sessions (id, user_id, vet_id, pet_id, specialty_id, priority, status, mode, created_at, updated_at)
         values (gen_random_uuid(), auth.uid(), $1::uuid, $2::uuid, $3::uuid, $4, 'scheduled', $5, now(), now())
         returning id`,
        [normalized.vetId, normalized.petId, normalized.specialtyId, normalized.priority, normalized.mode]
      );
      const sessionId = sessionRows[0]?.id;
      if (!sessionId) throw new BadRequestException('session_create_failed');

      const { rows } = await q<any>(
        `insert into appointments (id, session_id, user_id, vet_id, status, starts_at, ends_at)
         values (gen_random_uuid(), $1::uuid, auth.uid(), $2::uuid, 'scheduled', $3::timestamptz, $4::timestamptz)
         returning id`,
        [sessionId, normalized.vetId, normalized.startsAt, endsAt]
      );
      const appointmentId = rows[0]?.id;
      if (!appointmentId) throw new BadRequestException('appointment_create_failed');
      return this.getById(q, appointmentId);
    });
  }

  private async listRows(q: TxQuery, limit: number, offset: number) {
    const { rows } = await q<any>(
      `${this.appointmentSelectSql()}
        where a.user_id = auth.uid() or a.vet_id = auth.uid()
        order by coalesce(a.starts_at, a.created_at) desc nulls last
        limit $1 offset $2`,
      [limit, offset]
    );
    return rows.map((row) => this.shapeRow(row));
  }

  private async getById(q: TxQuery, appointmentId: string) {
    const { rows } = await q<any>(
      `${this.appointmentSelectSql()}
        where a.id = $1::uuid
          and (a.user_id = auth.uid() or a.vet_id = auth.uid())
        limit 1`,
      [appointmentId]
    );
    if (!rows[0]) throw new BadRequestException('appointment_not_found');
    return this.shapeRow(rows[0]);
  }

  private appointmentSelectSql() {
    return `select a.id,
                  a.session_id,
                  a.user_id,
                  a.vet_id,
                  a.status,
                  a.starts_at,
                  a.ends_at,
                  coalesce(s.mode, 'video') as mode,
                  s.pet_id,
                  p.name as pet_name,
                  s.specialty_id,
                  vs.name as specialty_name,
                  vu.full_name as vet_name,
                  uu.full_name as user_name
             from appointments a
        left join chat_sessions s on s.id = a.session_id
        left join pets p on p.id = s.pet_id
        left join vet_specialties vs on vs.id = s.specialty_id
        left join users vu on vu.id = a.vet_id
        left join users uu on uu.id = a.user_id`;
  }

  private shapeRow(row: any) {
    return {
      id: row.id,
      session_id: row.session_id,
      sessionId: row.session_id,
      user_id: row.user_id,
      userId: row.user_id,
      user_name: row.user_name,
      userName: row.user_name,
      vet_id: row.vet_id,
      vetId: row.vet_id,
      vet_name: row.vet_name,
      vetName: row.vet_name,
      pet_id: row.pet_id,
      petId: row.pet_id,
      pet_name: row.pet_name,
      petName: row.pet_name,
      specialty_id: row.specialty_id,
      specialtyId: row.specialty_id,
      specialty_name: row.specialty_name,
      specialtyName: row.specialty_name,
      mode: row.mode || 'video',
      status: row.status,
      starts_at: row.starts_at,
      startsAt: row.starts_at,
      ends_at: row.ends_at,
      endsAt: row.ends_at,
    };
  }

  private normalizeCreateInput(input: AppointmentCreateInput) {
    const vetId = this.normalizeRequiredUuid(input.vetId || input.vet_id || '', 'vetId');
    const specialtyId = this.normalizeRequiredUuid(input.specialtyId || input.specialty_id || '', 'specialtyId');
    const rawPetId = input.petId ?? input.pet_id ?? null;
    const petId = rawPetId ? this.normalizeRequiredUuid(rawPetId, 'petId') : null;
    const rawStartsAt = input.startsAt || input.starts_at;
    if (!rawStartsAt) throw new BadRequestException('startsAt_required');
    const starts = new Date(rawStartsAt);
    if (Number.isNaN(starts.getTime())) throw new BadRequestException('startsAt_invalid');
    if (starts.getTime() <= Date.now()) throw new BadRequestException('startsAt_must_be_future');
    const priority = String(input.priority || 'routine').trim().toLowerCase();
    if (!['routine', 'urgent', 'emergency'].includes(priority)) throw new BadRequestException('priority_invalid');
    const mode = String(input.mode || 'video').trim().toLowerCase();
    if (mode !== 'chat' && mode !== 'video') throw new BadRequestException('mode_invalid');
    return {
      vetId,
      petId,
      specialtyId,
      startsAt: starts.toISOString(),
      durationMin: this.normalizeDuration(input.durationMin ?? input.duration_min),
      priority,
      mode,
    };
  }

  private normalizeRequiredUuid(value: string, field: string) {
    const normalized = String(value || '').trim();
    if (!normalized) throw new BadRequestException(`${field}_required`);
    this.validator.validateUUID(normalized, field);
    return normalized;
  }

  private normalizeDuration(value: unknown) {
    return Math.min(Math.max(Number(value || 30) || 30, 10), 240);
  }

  private async validateVetAndSpecialty(q: TxQuery, vetId: string, specialtyId: string) {
    const { rows } = await q<{ ok: boolean; is_approved: boolean }>(
      `select array_position(coalesce(v.specialties, '{}'::uuid[]), $1::uuid) is not null
           and exists (select 1 from vet_specialties vs where vs.id = $1::uuid and coalesce(vs.is_active, true)) as ok,
              is_approved
         from vets v
        where id = $2::uuid
        limit 1`,
      [specialtyId, vetId]
    );
    if (!rows[0]?.ok) throw new BadRequestException('vet_missing_specialty');
    if (!rows[0]?.is_approved) throw new BadRequestException('vet_not_approved');
  }

  private async validatePetForUser(q: TxQuery, petId: string) {
    const { rows } = await q<{ id: string }>(
      `select id
         from pets
        where id = $1::uuid
          and user_id = auth.uid()
        limit 1`,
      [petId]
    );
    if (!rows[0]) throw new BadRequestException('pet_not_found_for_user');
  }

  private async assertSlotAvailable(q: TxQuery, vetId: string, startsAt: string, endsAt: string) {
    const { rows: availability } = await q<{ ok: boolean }>(
      `select true as ok
         from vet_availability va
        where va.vet_id = $1::uuid
          and va.weekday = extract(dow from ($2::timestamptz at time zone coalesce(nullif(va.timezone, ''), 'America/Mexico_City')))::int
          and (($2::timestamptz at time zone coalesce(nullif(va.timezone, ''), 'America/Mexico_City'))::time >= va.start_time)
          and (($3::timestamptz at time zone coalesce(nullif(va.timezone, ''), 'America/Mexico_City'))::time <= va.end_time)
        limit 1`,
      [vetId, startsAt, endsAt]
    );
    if (!availability[0]) throw new BadRequestException('slot_outside_availability');

    const { rows: conflicts } = await q<{ id: string }>(
      `select id
         from appointments
        where vet_id = $1::uuid
          and status = any(array['scheduled','active','confirmed']::text[])
          and tstzrange(starts_at, ends_at) && tstzrange($2::timestamptz, $3::timestamptz)
        limit 1`,
      [vetId, startsAt, endsAt]
    );
    if (conflicts[0]) throw new ConflictException('vet_conflict');
  }

  private slotsSql(limit: number) {
    return `with params as (
       select $1::uuid as vet_id,
              $2::timestamptz as since,
              $3::timestamptz as until,
              $4::int as dur
     ),
     days as (
       select generate_series(date_trunc('day', (select since from params)), date_trunc('day', (select until from params)), interval '1 day')::date as day
     ),
     avail as (
       select d.day,
              va.start_time as start_t,
              va.end_time as end_t,
              coalesce(nullif(va.timezone, ''), 'America/Mexico_City') as tz
         from days d
         join vet_availability va on va.weekday = extract(dow from d.day) and va.vet_id = (select vet_id from params)
     ),
     ranges as (
       select make_timestamptz(extract(year from a.day)::int, extract(month from a.day)::int, extract(day from a.day)::int, extract(hour from a.start_t)::int, extract(minute from a.start_t)::int, 0, a.tz) as start_at,
              make_timestamptz(extract(year from a.day)::int, extract(month from a.day)::int, extract(day from a.day)::int, extract(hour from a.end_t)::int, extract(minute from a.end_t)::int, 0, a.tz) as end_at
         from avail a
     ),
     aligned_ranges as (
       select date_trunc('hour', r.start_at)
                + make_interval(secs => ceil(extract(epoch from (r.start_at - date_trunc('hour', r.start_at))) / 1800) * 1800) as start_at,
              r.end_at
         from ranges r
     ),
     slots as (
       select gs as slot_start, gs + make_interval(mins => (select dur from params)) as slot_end
         from aligned_ranges r,
              generate_series(r.start_at, r.end_at - make_interval(mins => (select dur from params)), make_interval(mins => (select dur from params))) as gs
     ),
     booked as (
       select tstzrange(starts_at, ends_at) as appt_range
         from appointments
        where vet_id = (select vet_id from params)
          and status = any(array['scheduled','active','confirmed']::text[])
     )
     select slot_start, slot_end
       from slots s
      where s.slot_start >= (select since from params)
        and s.slot_end <= (select until from params)
        and not exists (select 1 from booked b where tstzrange(s.slot_start, s.slot_end) && b.appt_range)
      order by slot_start asc
      limit ${Math.min(Math.max(limit, 1), 200)}`;
  }
}