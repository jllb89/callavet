import { Body, Controller, Get, HttpException, HttpStatus, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';

type ActorRole = 'user' | 'vet' | 'admin';
const UUID_RE = /^[0-9a-fA-F-]{36}$/;

function appointmentDurationMinutes(start: any, end: any): number {
  const startAt = new Date(start).getTime();
  const endAt = new Date(end).getTime();
  const diff = Math.round((endAt - startAt) / 60000);
  return diff > 0 ? diff : 30;
}

@Controller()
@UseGuards(AuthGuard)
export class AppointmentsController {
  constructor(private readonly db: DbService, private readonly rc: RequestContext) {}

  @Get('appointments')
  async list(
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string,
  ) {
    try {
      const limit = Math.min(Math.max(parseInt(limitStr || '20', 10) || 20, 1), 100);
      const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
      if (this.db.isStub) return { data: [], mode: 'stub' } as any;
      const rows = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `select id, user_id, vet_id, status, starts_at, ends_at
             from appointments
            where user_id = auth.uid() or vet_id = auth.uid()
            order by coalesce(starts_at, created_at) desc nulls last
            limit $1 offset $2`,
          [limit, offset]
        );
        return rows as any[];
      });
      return { data: rows };
    } catch (e: any) {
      throw new HttpException(e?.message || 'appointments_list_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('appointments')
  async create(@Body() body: { vetId: string; petId?: string; startsAt: string; durationMin?: number; specialtyId: string }) {
    try {
      if (!body?.vetId || !body?.startsAt) throw new HttpException('vetId_and_startsAt_required', HttpStatus.BAD_REQUEST);
      if (!body?.specialtyId) throw new HttpException('specialty_required', HttpStatus.BAD_REQUEST);
      if (!UUID_RE.test(body.vetId)) throw new HttpException('vetId_must_be_uuid', HttpStatus.BAD_REQUEST);
      if (!UUID_RE.test(body.specialtyId)) throw new HttpException('specialtyId_must_be_uuid', HttpStatus.BAD_REQUEST);
      if (body.petId && !UUID_RE.test(body.petId)) throw new HttpException('petId_must_be_uuid', HttpStatus.BAD_REQUEST);
      if (this.db.isStub) {
        return {
          id: `appt_${Date.now()}`,
          session_id: body.petId ? `sess_${Date.now()}` : null,
          user_id: (this.rc.claims && (this.rc.claims as any).sub) || 'user_stub',
          vet_id: body.vetId,
          status: 'scheduled',
          starts_at: body.startsAt,
          ends_at: new Date(new Date(body.startsAt).getTime() + ((body.durationMin || 30) * 60 * 1000)).toISOString(),
        } as any;
      }
      const row = await this.db.runInTx(async (q) => {
        // Validate vet approval and requested specialty coverage.
        const { rows: vetRows } = await q<{ ok: boolean; is_approved: boolean }>(
          `select array_position(specialties, $1::uuid) is not null as ok,
                  is_approved
             from vets
            where id = $2::uuid
            limit 1`,
          [body.specialtyId, body.vetId]
        );
        if (!vetRows[0]?.ok) throw new HttpException('vet_missing_specialty', HttpStatus.BAD_REQUEST);
        if (!vetRows[0]?.is_approved) throw new HttpException('vet_not_approved', HttpStatus.BAD_REQUEST);

        let sessionId: string | null = null;
        if (body.petId) {
          const { rows: petRows } = await q<{ id: string }>(
            `select id
               from pets
              where id = $1::uuid
                and user_id = auth.uid()
              limit 1`,
            [body.petId]
          );
          if (!petRows[0]) throw new HttpException('pet_not_found_for_user', HttpStatus.BAD_REQUEST);
          const { rows: sessionRows } = await q<{ id: string }>(
            `insert into chat_sessions (id, user_id, vet_id, pet_id, status, mode, created_at, updated_at)
             values (gen_random_uuid(), auth.uid(), $1::uuid, $2::uuid, 'scheduled', 'video', now(), now())
             returning id`,
            [body.vetId, body.petId]
          );
          sessionId = sessionRows[0]?.id || null;
        }

        // Simple conflict check: ensure vet is free in the requested window
        const duration = body.durationMin || 30;
        const { rows: conflicts } = await q(
          `select id from appointments
            where vet_id = $1
              and status in ('scheduled','active','confirmed')
              and tstzrange(starts_at, ends_at) && tstzrange($2::timestamptz, ($2::timestamptz + make_interval(mins => $3)))
            limit 1`,
          [body.vetId, body.startsAt, duration]
        );
        if (conflicts[0]) throw new HttpException('vet_conflict', HttpStatus.CONFLICT);
        const { rows } = await q(
          `insert into appointments (id, session_id, user_id, vet_id, status, starts_at, ends_at)
           values (gen_random_uuid(), $1::uuid, auth.uid(), $2::uuid, 'scheduled', $3::timestamptz, ($3::timestamptz + make_interval(mins => $4)))
           returning id, session_id, user_id, vet_id, status, starts_at, ends_at`,
          [sessionId, body.vetId, body.startsAt, duration]
        );
        return rows[0];
      });
      return row;
    } catch (e: any) {
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'appointments_create_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Patch('appointments/:id')
  async patch(
    @Param('id') id: string,
    @Body() body: { status?: string; startsAt?: string; endsAt?: string; durationMin?: number }
  ) {
    try {
      if (this.db.isStub) return { id, status: body.status || 'scheduled' } as any;
      const actorId = this.rc.requireUuidUserId();
      const row = await this.db.runInTx(async (q) => {
        const { rows: actorRows } = await q<{ role: ActorRole }>(
          `select role from users where id = $1::uuid limit 1`,
          [actorId]
        );
        const actorRole = actorRows[0]?.role;
        if (!actorRole) throw new HttpException('actor_not_found', HttpStatus.FORBIDDEN);

        const { rows: appointmentRows } = await q<any>(
          `select id, session_id, user_id, vet_id, status, starts_at, ends_at
             from appointments
            where id = $1::uuid
            limit 1`,
          [id]
        );
        const appointment = appointmentRows[0];
        if (!appointment) return null;
        const isAdmin = actorRole === 'admin';
        const isOwner = appointment.user_id === actorId;
        const isVet = appointment.vet_id === actorId;
        if (!isAdmin && !isOwner && !isVet) return null;

        const requestedStatus = body.status ? String(body.status).toLowerCase() : null;
        let nextStatus = appointment.status;
        let startsAt = body.startsAt ? new Date(body.startsAt).toISOString() : new Date(appointment.starts_at).toISOString();
        let endsAt = body.endsAt ? new Date(body.endsAt).toISOString() : new Date(appointment.ends_at).toISOString();

        if (body.startsAt || body.endsAt || typeof body.durationMin === 'number') {
          if (!['scheduled', 'confirmed'].includes(appointment.status) && !isAdmin) {
            throw new HttpException('reschedule_requires_scheduled_or_confirmed_status', HttpStatus.BAD_REQUEST);
          }
          const duration = typeof body.durationMin === 'number'
            ? body.durationMin
            : body.endsAt
              ? appointmentDurationMinutes(body.startsAt || appointment.starts_at, body.endsAt)
              : appointmentDurationMinutes(appointment.starts_at, appointment.ends_at);
          startsAt = body.startsAt ? new Date(body.startsAt).toISOString() : new Date(appointment.starts_at).toISOString();
          endsAt = body.endsAt
            ? new Date(body.endsAt).toISOString()
            : new Date(new Date(startsAt).getTime() + (duration * 60 * 1000)).toISOString();
          const { rows: conflicts } = await q<{ id: string }>(
            `select id
               from appointments
              where vet_id = $1::uuid
                and id <> $2::uuid
                and status in ('scheduled', 'confirmed', 'active')
                and tstzrange(starts_at, ends_at) && tstzrange($3::timestamptz, $4::timestamptz)
              limit 1`,
            [appointment.vet_id, id, startsAt, endsAt]
          );
          if (conflicts[0]) throw new HttpException('vet_conflict', HttpStatus.CONFLICT);
        }

        if (requestedStatus) {
          const allowed = new Set<string>();
          if (isAdmin || isVet) {
            if (appointment.status === 'scheduled') ['confirmed', 'active', 'canceled'].forEach((value) => allowed.add(value));
            if (appointment.status === 'confirmed') ['active', 'canceled'].forEach((value) => allowed.add(value));
            if (appointment.status === 'active') ['completed', 'no_show', 'canceled'].forEach((value) => allowed.add(value));
          }
          if (isAdmin || isOwner) {
            if (appointment.status === 'scheduled' || appointment.status === 'confirmed') {
              allowed.add('canceled');
            }
          }
          if (!allowed.has(requestedStatus)) {
            throw new HttpException('invalid_appointment_transition', HttpStatus.BAD_REQUEST);
          }
          nextStatus = requestedStatus;
        }

        let sessionId = appointment.session_id || null;
        if (nextStatus === 'active') {
          if (!sessionId) {
            const { rows: sessionRows } = await q<{ id: string }>(
              `insert into chat_sessions (id, user_id, vet_id, status, mode, started_at, created_at, updated_at)
               values (gen_random_uuid(), $1::uuid, $2::uuid, 'active', 'video', now(), now(), now())
               returning id`,
              [appointment.user_id, appointment.vet_id]
            );
            sessionId = sessionRows[0]?.id || null;
          } else {
            await q(
              `update chat_sessions
                  set vet_id = $2::uuid,
                      status = 'active',
                      mode = coalesce(mode, 'video'),
                      started_at = coalesce(started_at, now()),
                      updated_at = now()
                where id = $1::uuid`,
              [sessionId, appointment.vet_id]
            );
          }
        }

        if (['completed', 'canceled', 'no_show'].includes(nextStatus) && sessionId) {
          const sessionStatus = nextStatus === 'completed' ? 'completed' : 'canceled';
          await q(
            `update chat_sessions
                set status = $2,
                    ended_at = coalesce(ended_at, now()),
                    updated_at = now()
              where id = $1::uuid`,
            [sessionId, sessionStatus]
          );
        }

        const { rows } = await q<any>(
          `update appointments
              set session_id = $2::uuid,
                  status = $3,
                  starts_at = $4::timestamptz,
                  ends_at = $5::timestamptz
            where id = $1::uuid
            returning id, session_id, user_id, vet_id, status, starts_at, ends_at`,
          [id, sessionId, nextStatus, startsAt, endsAt]
        );
        return rows[0];
      });
      if (!row) throw new HttpException('not_found', HttpStatus.NOT_FOUND);
      return row;
    } catch (e: any) {
      if (e instanceof HttpException) throw e;
      throw new HttpException(e?.message || 'appointments_patch_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('appointments/:id/transitions')
  async transition(
    @Param('id') id: string,
    @Body() body: { status?: string; to?: string }
  ) {
    return this.patch(id, { status: body?.to || body?.status });
  }

  @Get('vets/:vetId/availability/slots')
  async slots(
    @Param('vetId') vetId: string,
    @Query('since') since?: string,
    @Query('until') until?: string,
    @Query('durationMin') durationStr?: string,
  ) {
    try {
      if (this.db.isStub) return { data: [] } as any;
      const durationMin = Math.min(Math.max(parseInt(durationStr || '30', 10) || 30, 10), 240);
      const rows = await this.db.runInTx(async (q) => {
        // Compute slots from daily availability blocks (vet_availability), exclude conflicts with existing appointments
        const { rows: slots } = await q<any>(
          `with params as (
             select $1::uuid as vet_id,
                    coalesce($2::timestamptz, now()) as since,
                    coalesce($3::timestamptz, now() + interval '7 days') as until,
                    $4::int as dur
           ),
           days as (
             select generate_series(date_trunc('day', (select since from params)), date_trunc('day', (select until from params)), interval '1 day')::date as day
           ),
           avail as (
             select d.day,
                    va.start_time as start_t,
                    va.end_time as end_t
               from days d
               join vet_availability va on va.weekday = extract(dow from d.day) and va.vet_id = (select vet_id from params)
           ),
           ranges as (
             select make_timestamptz(extract(year from a.day)::int, extract(month from a.day)::int, extract(day from a.day)::int, extract(hour from a.start_t)::int, extract(minute from a.start_t)::int, 0) as start_at,
                    make_timestamptz(extract(year from a.day)::int, extract(month from a.day)::int, extract(day from a.day)::int, extract(hour from a.end_t)::int, extract(minute from a.end_t)::int, 0) as end_at
               from avail a
           ),
           slots as (
             select gs as slot_start, gs + make_interval(mins => (select dur from params)) as slot_end
               from ranges r,
                    generate_series(r.start_at, r.end_at - make_interval(mins => (select dur from params)), make_interval(mins => (select dur from params))) as gs
           ),
           booked as (
             select tstzrange(starts_at, ends_at) as appt_range
               from appointments
              where vet_id = (select vet_id from params)
                and status in ('scheduled','active','confirmed')
           )
           select slot_start, slot_end
             from slots s
            where not exists (
              select 1 from booked b where tstzrange(s.slot_start, s.slot_end) && b.appt_range
            )
            order by slot_start asc
            limit 200`,
          [vetId, since || null, until || null, durationMin]
        );
        return slots.map((r: any) => ({ start: r.slot_start, end: r.slot_end }));
      });
      return { data: rows };
    } catch (e: any) {
      throw new HttpException(e?.message || 'slots_failed', HttpStatus.BAD_REQUEST);
    }
  }
}
