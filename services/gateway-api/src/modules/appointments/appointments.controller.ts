import { Body, Controller, Get, HttpException, HttpStatus, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';
import { NotificationsService } from '../notifications/notifications.service';
import { AppointmentSchedulingService, AppointmentCreateInput } from './appointment-scheduling.service';

function appointmentDurationMinutes(start: any, end: any): number {
  const startAt = new Date(start).getTime();
  const endAt = new Date(end).getTime();
  const diff = Math.round((endAt - startAt) / 60000);
  return diff > 0 ? diff : 30;
}

@Controller()
@UseGuards(AuthGuard)
export class AppointmentsController {
  constructor(
    private readonly rc: RequestContext,
    private readonly notifications: NotificationsService,
    private readonly scheduling: AppointmentSchedulingService,
    private readonly db: DbService,
  ) {}

  @Get('appointments')
  async list(
    @Query('limit') limitStr?: string,
    @Query('offset') offsetStr?: string,
  ) {
    try {
      const limit = Math.min(Math.max(parseInt(limitStr || '20', 10) || 20, 1), 100);
      const offset = Math.max(parseInt(offsetStr || '0', 10) || 0, 0);
      return { data: await this.scheduling.listForActor(limit, offset) };
    } catch (e: any) {
      throw new HttpException(e?.message || 'appointments_list_failed', HttpStatus.BAD_REQUEST);
    }
  }

  @Post('appointments')
  async create(@Body() body: AppointmentCreateInput) {
    try {
      const row = await this.scheduling.createScheduledConsult(body);
      // Fire-and-forget notification: appointment scheduled
      try {
        this.notifications.sendEvent({
          eventType: 'appointment.scheduled',
          userId: row?.user_id,
          channel: 'email',
          variables: {
            appointmentId: row?.id,
            vetId: row?.vet_id,
            startsAt: row?.starts_at,
          },
        }).catch(e => console.error('[appointment.create] notification failed:', e));
      } catch (e) {
        // Swallow notification errors; do not block appointment creation
      }
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
      
      // Fetch old appointment status before transaction for notifications
      const oldAppointmentData = await this.db.runInTx(async (q) => {
        const { rows } = await q<{ status: string; user_id: string }>(
          `select status, user_id from appointments where id = $1::uuid limit 1`,
          [id]
        );
        return rows[0];
      });
      const oldStatus = oldAppointmentData?.status;
      
      const row = await this.db.runInTx(async (q) => {
        const { rows: actorRows } = await q<{ role: string }>(
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
                and status = ANY(ARRAY['scheduled', 'confirmed', 'active']::text[])
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
      // Fire-and-forget notifications for status transitions
      const newStatus = row?.status;
      try {
        if (newStatus === 'active' && oldStatus !== 'active') {
          // Consult starting
          this.notifications.sendEvent({
            eventType: 'consult.start',
            userId: row?.user_id,
            channel: 'email',
            variables: {
              appointmentId: row?.id,
              sessionId: row?.session_id,
              vetId: row?.vet_id,
            },
          }).catch(e => console.error('[appointment.patch:active] notification failed:', e));
        } else if (['completed', 'canceled', 'no_show'].includes(newStatus || '') && !['completed', 'canceled', 'no_show'].includes(oldStatus || '')) {
          // Consult ending
          this.notifications.sendEvent({
            eventType: 'consult.end',
            userId: row?.user_id,
            channel: 'email',
            variables: {
              appointmentId: row?.id,
              sessionId: row?.session_id,
              reason: newStatus,
            },
          }).catch(e => console.error('[appointment.patch:end] notification failed:', e));
        }
      } catch (e) {
        // Swallow notification errors; do not block status update
      }
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
      const rows = await this.scheduling.availableSlots({ vetId, since, until, durationMin, limit: 200 });
      return { data: rows };
    } catch (e: any) {
      throw new HttpException(e?.message || 'slots_failed', HttpStatus.BAD_REQUEST);
    }
  }
}
