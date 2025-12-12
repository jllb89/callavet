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
          `select id, user_id, vet_id, pet_id, status, scheduled_at, duration_min, notes
             from appointments
            where user_id = auth.uid() or vet_id = auth.uid()
            order by coalesce(scheduled_at, created_at) desc nulls last
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
  async create(@Body() body: { vetId: string; petId?: string; scheduledAt: string; durationMin?: number; notes?: string }) {
    try {
      if (!body?.vetId || !body?.scheduledAt) throw new HttpException('vetId_and_scheduledAt_required', HttpStatus.BAD_REQUEST);
      if (this.db.isStub) {
        return {
          id: `appt_${Date.now()}`,
          user_id: (this.rc.claims && (this.rc.claims as any).sub) || 'user_stub',
          vet_id: body.vetId,
          pet_id: body.petId || null,
          status: 'scheduled',
          scheduled_at: body.scheduledAt,
          duration_min: body.durationMin || 30,
          notes: body.notes || null,
        } as any;
      }
      const row = await this.db.runInTx(async (q) => {
        // Simple conflict check: ensure vet is free in the requested window
        const duration = body.durationMin || 30;
        const { rows: conflicts } = await q(
          `select id from appointments
            where vet_id = $1
              and status in ('scheduled','confirmed')
              and tsrange(scheduled_at, scheduled_at + make_interval(mins => duration_min)) && tsrange($2::timestamptz, ($2::timestamptz + make_interval(mins => $3)))
            limit 1`,
          [body.vetId, body.scheduledAt, duration]
        );
        if (conflicts[0]) throw new HttpException('vet_conflict', HttpStatus.CONFLICT);
        const { rows } = await q(
          `insert into appointments (id, user_id, vet_id, pet_id, status, scheduled_at, duration_min, notes)
           values (gen_random_uuid(), auth.uid(), $1::uuid, $2::uuid, 'scheduled', $3::timestamptz, $4::int, $5::text)
           returning id, user_id, vet_id, pet_id, status, scheduled_at, duration_min, notes`,
          [body.vetId, body.petId || null, body.scheduledAt, duration, body.notes || null]
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
    @Body() body: { status?: string; scheduledAt?: string; durationMin?: number; notes?: string }
  ) {
    try {
      if (this.db.isStub) return { id, status: body.status || 'scheduled' } as any;
      const updateFields: string[] = [];
      const values: any[] = [id];
      let idx = 2;
      if (body.status) { updateFields.push(`status = $${idx++}`); values.push(String(body.status).toLowerCase()); }
      if (body.scheduledAt) { updateFields.push(`scheduled_at = $${idx++}::timestamptz`); values.push(body.scheduledAt); }
      if (typeof body.durationMin === 'number') { updateFields.push(`duration_min = $${idx++}::int`); values.push(body.durationMin); }
      if (typeof body.notes === 'string') { updateFields.push(`notes = $${idx++}::text`); values.push(body.notes); }
      if (!updateFields.length) throw new HttpException('no_fields', HttpStatus.BAD_REQUEST);
      const setSql = updateFields.join(', ');
      const row = await this.db.runInTx(async (q) => {
        const { rows } = await q(
          `update appointments
              set ${setSql}, updated_at = now()
            where id = $1
              and (user_id = auth.uid() or vet_id = auth.uid())
            returning id, user_id, vet_id, pet_id, status, scheduled_at, duration_min, notes`,
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
        // Prefer existing materialized view or table `vet_availability_slots`; otherwise compute naive slots from availability + exclude booked
        const { rows: direct } = await q<any>(
          `select start_at as slot_start, end_at as slot_end
             from vet_availability_slots
            where vet_id = $1
              and ($2::timestamptz is null or start_at >= $2::timestamptz)
              and ($3::timestamptz is null or end_at <= $3::timestamptz)
              and slot_duration_min = $4
            order by start_at asc
            limit 200`,
          [vetId, since || null, until || null, durationMin]
        );
        if (direct && direct.length) return direct.map((r: any) => ({ start: r.slot_start, end: r.slot_end }));
        // Fallback naive computation from daily availability blocks
        const { rows: blocks } = await q<any>(
          `select day, start_time, end_time
             from vets_availability
            where vet_id = $1
              and is_active
            order by day asc, start_time asc`,
          [vetId]
        );
        // Generate slots in SQL; exclude conflicts with existing appointments
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
                    (va.start_time)::time as start_t,
                    (va.end_time)::time as end_t
               from days d
               join vets_availability va on va.day = extract(dow from d.day) and va.vet_id = (select vet_id from params) and va.is_active
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
             select tsrange(scheduled_at, scheduled_at + make_interval(mins => duration_min)) as appt_range
               from appointments
              where vet_id = (select vet_id from params)
                and status in ('scheduled','confirmed')
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
