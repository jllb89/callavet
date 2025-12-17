import { Body, Controller, Get, HttpException, HttpStatus, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { DbService } from '../db/db.service';
import { AuthGuard } from '../auth/auth.guard';
import { RequestContext } from '../auth/request-context.service';

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
      if (this.db.isStub) {
        return {
          id: `appt_${Date.now()}`,
          user_id: (this.rc.claims && (this.rc.claims as any).sub) || 'user_stub',
          vet_id: body.vetId,
          status: 'scheduled',
          starts_at: body.startsAt,
          ends_at: new Date(new Date(body.startsAt).getTime() + ((body.durationMin || 30) * 60 * 1000)).toISOString(),
        } as any;
      }
      const row = await this.db.runInTx(async (q) => {
        // Validate vet covers requested specialty: check vets.specialties contains provided id
        const { rows: vetRows } = await q<{ ok: boolean }>(
          `select array_position(specialties, $1::uuid) is not null as ok from vets where id = $2::uuid limit 1`,
          [body.specialtyId, body.vetId]
        );
        if (!vetRows[0]?.ok) throw new HttpException('vet_missing_specialty', HttpStatus.BAD_REQUEST);
        // Simple conflict check: ensure vet is free in the requested window
        const duration = body.durationMin || 30;
        const { rows: conflicts } = await q(
          `select id from appointments
            where vet_id = $1
              and status in ('scheduled','active','confirmed')
              and tsrange(starts_at, ends_at) && tsrange($2::timestamptz, ($2::timestamptz + make_interval(mins => $3)))
            limit 1`,
          [body.vetId, body.startsAt, duration]
        );
        if (conflicts[0]) throw new HttpException('vet_conflict', HttpStatus.CONFLICT);
        const { rows } = await q(
          `insert into appointments (id, user_id, vet_id, status, starts_at, ends_at)
           values (gen_random_uuid(), auth.uid(), $1::uuid, 'scheduled', $2::timestamptz, ($2::timestamptz + make_interval(mins => $3)))
           returning id, user_id, vet_id, status, starts_at, ends_at`,
          [body.vetId, body.startsAt, duration]
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
      const updateFields: string[] = [];
      const values: any[] = [id];
      let idx = 2;
      if (body.status) { updateFields.push(`status = $${idx++}`); values.push(String(body.status).toLowerCase()); }
      if (body.startsAt) { updateFields.push(`starts_at = $${idx++}::timestamptz`); values.push(body.startsAt); }
      if (body.endsAt) { updateFields.push(`ends_at = $${idx++}::timestamptz`); values.push(body.endsAt); }
      if (typeof body.durationMin === 'number' && body.startsAt) { updateFields.push(`ends_at = ($${idx-1}::timestamptz + make_interval(mins => $${idx++}))`); values.push(body.durationMin); }
      if (!updateFields.length) throw new HttpException('no_fields', HttpStatus.BAD_REQUEST);
      const setSql = updateFields.join(', ');
      const row = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `update appointments
              set ${setSql}
            where id = $1
              and (user_id = auth.uid() or vet_id = auth.uid())
            returning id, user_id, vet_id, status, starts_at, ends_at`,
          values
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
             select tsrange(starts_at, ends_at) as appt_range
               from appointments
              where vet_id = (select vet_id from params)
                and status in ('scheduled','active','confirmed')
           )
           select slot_start, slot_end
             from slots s
            where not exists (
              select 1 from booked b where tsrange(s.slot_start, s.slot_end) && b.appt_range
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
